using System.Globalization;
using System.Buffers;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Runtime.Versioning;
using Microsoft.Data.Sqlite;

namespace ClipDiary.Core;

/// <summary>Local-only store. All calls are serialized; use RunAsync or a dedicated worker from UI code.</summary>
public sealed class ClipStore : IDisposable
{
    public const int MaximumTextBytes = 1024 * 1024;
    public const int MaximumImageBytes = 25 * 1024 * 1024;
    public const long MaximumPixels = 50_000_000;
    public const long MaximumStorageBytes = 512L * 1024 * 1024;
    public const int MaximumRecords = 10_000;
    public static readonly TimeSpan Retention = TimeSpan.FromHours(96);
    private const string Columns = "id,kind,CAST(text AS BLOB),CAST(title AS BLOB),captured,expires,CAST(source AS BLOB),snippet,asset,thumbnail,bytes,parameterized";
    private readonly object _gate = new();
    private readonly SqliteConnection _db;
    private readonly string _assets, _thumbnails;
    private readonly HashSet<string> _pendingRemovals = new(PathComparer);
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);
    private bool _disposed;
    private CancellationToken _operationCancellation;
    public string DirectoryPath { get; }
    public string Directory => DirectoryPath;
    private static StringComparer PathComparer => OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal;

    public ClipStore(string directory)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        DirectoryPath = Path.GetFullPath(directory);
        System.IO.Directory.CreateDirectory(DirectoryPath);
        // A root alias is intentional; internal paths must not redirect to unrelated data.
        var rootInfo = new DirectoryInfo(DirectoryPath);
        if (rootInfo.LinkTarget is not null) DirectoryPath = rootInfo.ResolveLinkTarget(true)!.FullName;
        _assets = Path.Combine(DirectoryPath, "Assets");
        _thumbnails = Path.Combine(DirectoryPath, "Thumbnails");
        foreach (var folder in new[] { DirectoryPath, _assets, _thumbnails })
        {
            if (!PathComparer.Equals(folder, DirectoryPath)) RejectLink(folder);
            System.IO.Directory.CreateDirectory(folder);
            MakePrivate(folder, directory: true);
        }
        string file = Path.Combine(DirectoryPath, "history.sqlite3");
        foreach (string suffix in new[] { "", "-journal", "-wal", "-shm" }) RejectLink(file + suffix);
        _db = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = file, Mode = SqliteOpenMode.ReadWriteCreate, Cache = SqliteCacheMode.Private,
          Pooling = false, DefaultTimeout = 3 }.ToString());
        try
        {
            _db.Open();
            long version = Convert.ToInt64(Scalar("PRAGMA user_version"), CultureInfo.InvariantCulture);
            if (version > 1) throw new ClipStoreException("This history was created by a newer ClipDiary version.");
            Execute("PRAGMA journal_mode=DELETE");
            Execute("PRAGMA synchronous=FULL");
            Execute("PRAGMA secure_delete=ON");
            using (var transaction = _db.BeginTransaction())
            {
                Execute("CREATE TABLE IF NOT EXISTS clips(id TEXT PRIMARY KEY,kind TEXT NOT NULL,text TEXT,title TEXT NOT NULL,captured INTEGER NOT NULL,expires INTEGER,source TEXT NOT NULL,snippet INTEGER NOT NULL,asset TEXT,thumbnail TEXT,bytes INTEGER NOT NULL,digest TEXT,parameterized INTEGER NOT NULL DEFAULT 0)", transaction: transaction);
                Execute("CREATE INDEX IF NOT EXISTS clips_expiry ON clips(expires)", transaction: transaction);
                Execute("CREATE INDEX IF NOT EXISTS clips_collection_capture ON clips(snippet,captured)", transaction: transaction);
                Execute("PRAGMA user_version=1", transaction: transaction);
                transaction.Commit();
            }
            MakePrivate(file, directory: false);
            _db.CreateFunction<byte[]?, int, byte[]?>("clip_preview", PreviewBytes, isDeterministic: true);
            Purge();
            Reconcile();
        }
        catch { _db.Dispose(); throw; }
    }

    public Task<T> RunAsync<T>(Func<ClipStore, T> action, CancellationToken cancellationToken = default) =>
        Task.Run(() =>
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_gate)
            {
                EnsureOpen(); cancellationToken.ThrowIfCancellationRequested();
                var previous = _operationCancellation;
                _operationCancellation = cancellationToken;
                try { return action(this); }
                finally { _operationCancellation = previous; }
            }
        }, cancellationToken);
    public Task RunAsync(Action<ClipStore> action, CancellationToken cancellationToken = default) =>
        RunAsync(store => { action(store); return true; }, cancellationToken);

    public IReadOnlyList<ClipRecord> Records(string query = "", bool snippets = false, ClipKind? kind = null,
        int? previewLimit = null, CancellationToken cancellationToken = default)
    {
        lock (_gate)
        {
            EnsureOpen();
            if (!cancellationToken.CanBeCanceled) cancellationToken = _operationCancellation;
            cancellationToken.ThrowIfCancellationRequested();
            string projection = previewLimit is null ? Columns :
                "id,kind,clip_preview(CAST(text AS BLOB),@limit),clip_preview(CAST(title AS BLOB),@limit),captured,expires,clip_preview(CAST(source AS BLOB),@limit),snippet,asset,thumbnail,bytes,parameterized";
            string sql = $"SELECT {projection} FROM clips WHERE snippet=@snippet AND (expires IS NULL OR expires>@now)";
            var parameters = new List<(string, object?)> { ("@snippet", snippets ? 1 : 0), ("@now", Stamp(DateTimeOffset.UtcNow)) };
            if (previewLimit is not null) parameters.Add(("@limit", Math.Max(0, previewLimit.Value)));
            if (kind is not null) { sql += " AND kind=@kind"; parameters.Add(("@kind", KindText(kind.Value))); }
            if (query.Length > 0)
            {
                if (Utf8(query) > MaximumTextBytes) throw new ClipStoreException("Search exceeds the 1 MiB text limit.");
                var regex = new Regex(Regex.Escape(query.Normalize(NormalizationForm.FormC)),
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, TimeSpan.FromSeconds(1));
                _db.CreateFunction<byte[]?, bool>("clip_match", value =>
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    return value is not null && regex.IsMatch(StrictUtf8.GetString(value).Normalize(NormalizationForm.FormC));
                }, isDeterministic: true);
                sql += " AND (clip_match(CAST(title AS BLOB)) OR clip_match(CAST(text AS BLOB)) OR clip_match(CAST(source AS BLOB)))";
            }
            sql += " ORDER BY captured DESC,rowid DESC";
            try { return Fetch(sql, parameters, cancellationToken); }
            catch (Exception) when (cancellationToken.IsCancellationRequested) { throw new OperationCanceledException(cancellationToken); }
            finally { if (query.Length > 0) _db.CreateFunction<byte[]?, bool>("clip_match", _ => false); }
        }
    }
    public ClipRecord? Record(string id, DateTimeOffset? now = null)
    {
        lock (_gate) { EnsureOpen(); return Fetch($"SELECT {Columns} FROM clips WHERE id=@id AND (expires IS NULL OR expires>@now)", [("@id", id), ("@now", Stamp(now ?? DateTimeOffset.UtcNow))]).FirstOrDefault(); }
    }
    public ClipRecord? AddText(string text, string source, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            EnsureOpen();
            if (string.IsNullOrWhiteSpace(text)) return null;
            ValidateText(text); string title = TitleFor(text); ValidateMetadata(title, source);
            var date = now ?? DateTimeOffset.UtcNow; Purge(date);
            string digest = Digest(Encoding.UTF8.GetBytes(text));
            if (Duplicate(digest, ClipKind.Text, date) is { } duplicate) return duplicate;
            int bytes = Utf8(text); Capacity(bytes + Metadata(title, source));
            var record = new ClipRecord(Guid.NewGuid().ToString("D"), ClipKind.Text, text, title, date, date + Retention,
                source, false, null, null, bytes);
            Insert(record, digest); return record;
        }
    }
    /// <summary>Caller must validate codec/pixel count (<=50 MP) and generate a <=320 px thumbnail before passing bytes.</summary>
    public ClipRecord? AddImage(byte[] data, byte[] thumbnail, string extension, string title, string source,
        DateTimeOffset? now = null, bool deduplicate = true)
    {
        lock (_gate)
        {
            EnsureOpen(); ArgumentNullException.ThrowIfNull(data); ArgumentNullException.ThrowIfNull(thumbnail);
            extension = extension.TrimStart('.').ToLowerInvariant();
            if (!new[] { "png", "jpg", "jpeg", "tif", "tiff", "bmp", "gif", "webp", "heic", "heif" }.Contains(extension, StringComparer.Ordinal))
                throw new ClipStoreException("Unsupported image extension.");
            if (data.Length is 0 or > MaximumImageBytes || thumbnail.Length is 0 or > MaximumTextBytes)
                throw new ClipStoreException("Image exceeds 25 MiB or thumbnail exceeds 1 MiB.");
            ValidateMetadata(title, source); var date = now ?? DateTimeOffset.UtcNow; Purge(date);
            string digest = Digest(data);
            if (deduplicate && Duplicate(digest, ClipKind.Image, date) is { } duplicate) return duplicate;
            long bytes = (long)data.Length + thumbnail.Length; Capacity(bytes + Metadata(title, source));
            string id = Guid.NewGuid().ToString("D"), asset = Path.Combine(_assets, id + "." + extension), thumb = Path.Combine(_thumbnails, id + ".png");
            try
            {
                WritePrivate(asset, data); WritePrivate(thumb, thumbnail);
                var record = new ClipRecord(id, ClipKind.Image, null, title, date, date + Retention, source, false, asset, thumb, bytes);
                Insert(record, digest); return record;
            }
            catch { QueueCleanup(asset, thumb); throw; }
        }
    }
    public void SaveSnippet(string id, string? title = null)
    {
        lock (_gate)
        {
            EnsureOpen(); var now = DateTimeOffset.UtcNow; var item = Record(id, now) ?? throw Missing();
            if (item.IsSnippet) return; Purge(now);
            CopyIndependent(item, string.IsNullOrWhiteSpace(title) ? item.Title : title, item.CapturedAt, snippet: true);
        }
    }
    public void CreateSnippet(string title, string text)
    {
        lock (_gate)
        {
            EnsureOpen(); title = string.IsNullOrWhiteSpace(title) ? TitleFor(text) : title;
            ValidateSnippet(title, text); Purge(); Capacity(Utf8(text) + Metadata(title, "Snippet"));
            Insert(new ClipRecord(Guid.NewGuid().ToString("D"), ClipKind.Text, text, title, DateTimeOffset.UtcNow,
                null, "Snippet", true, null, null, Utf8(text)), null);
        }
    }
    public void UpdateSnippet(string id, string title, string? text, bool? parameterized = null)
    {
        lock (_gate)
        {
            EnsureOpen(); var item = Record(id) ?? throw Missing(); if (!item.IsSnippet) throw new ClipStoreException("Only snippets can be edited.");
            text ??= item.Text; title = string.IsNullOrWhiteSpace(title) ? (text is null ? "Image snippet" : TitleFor(text)) : title;
            ValidateMetadata(title, item.Source); Purge();
            if (item.Kind == ClipKind.Text)
            {
                ValidateSnippet(title, text ?? "");
                Capacity(Utf8(text!) - item.ByteCount + Utf8(title) - Utf8(item.Title), 0);
                Execute("UPDATE clips SET title=@title,text=@text,bytes=@bytes,digest=NULL,parameterized=@parameterized WHERE id=@id",
                    [("@title",title),("@text",text),("@bytes",Utf8(text!)),("@parameterized",parameterized ?? item.IsParameterized ? 1 : 0),("@id",id)]);
            }
            else
            {
                Capacity(Utf8(title) - Utf8(item.Title), 0);
                Execute("UPDATE clips SET title=@title WHERE id=@id", [("@title",title),("@id",id)]);
            }
        }
    }
    public void SetParameterized(string id, bool enabled)
    {
        lock (_gate)
        {
            EnsureOpen(); var item = Record(id) ?? throw Missing();
            if (!item.IsSnippet || item.Kind != ClipKind.Text) throw new ClipStoreException("Only text snippets can be parameterized.");
            Execute("UPDATE clips SET parameterized=@value WHERE id=@id", [("@value",enabled ? 1 : 0),("@id",id)]);
        }
    }
    public ClipRecord Recopy(string id, IReadOnlyDictionary<string, string>? parameters = null, DateTimeOffset? now = null)
    {
        lock (_gate)
        {
            EnsureOpen(); var date = now ?? DateTimeOffset.UtcNow; var item = Record(id, date) ?? throw Missing();
            if (item.IsSnippet)
            {
                Purge(date);
                if (item.IsParameterized && item.Kind == ClipKind.Text)
                {
                    string text = SnippetParameters.Render(item.Text ?? "", parameters); ValidateText(text); ValidateMetadata(item.Title,item.Source);
                    Capacity(Utf8(text) + Metadata(item.Title,item.Source));
                    var rendered = item with { Id=Guid.NewGuid().ToString("D"),Text=text,CapturedAt=date,ExpiresAt=date+Retention,
                        IsSnippet=false,IsParameterized=false,ByteCount=Utf8(text) };
                    Insert(rendered,null); return rendered;
                }
                return CopyIndependent(item,item.Title,date,snippet:false);
            }
            if (item.Kind == ClipKind.Image && (item.AssetPath is null || !File.Exists(item.AssetPath))) throw Missing();
            Execute("UPDATE clips SET rowid=(SELECT COALESCE(MAX(rowid),0)+1 FROM clips),captured=@now,expires=@expiry WHERE id=@id",
                [("@now",Stamp(date)),("@expiry",Stamp(date+Retention)),("@id",id)]);
            return Record(id,date) ?? throw Missing();
        }
    }
    public void Delete(string id) { lock (_gate) { EnsureOpen(); Remove("id=@id",[("@id",id)]); } }
    public void ClearHistory() { lock (_gate) { EnsureOpen(); Remove("snippet=0",[]); } }
    public void DeleteAll() { lock (_gate) { EnsureOpen(); Remove("1=1",[]); RetryRemovals(); } }
    public void Purge(DateTimeOffset? now = null)
    {
        lock (_gate) { EnsureOpen(); Remove("snippet=0 AND expires<=@now",[("@now",Stamp(now ?? DateTimeOffset.UtcNow))]); RetryRemovals(); }
    }
    public ClipStats Stats()
    {
        lock (_gate)
        {
            EnsureOpen(); using var cmd = Command("SELECT COALESCE(SUM(CASE WHEN snippet=0 THEN 1 ELSE 0 END),0),COALESCE(SUM(CASE WHEN snippet=1 THEN 1 ELSE 0 END),0),COALESCE(SUM(bytes+length(CAST(title AS BLOB))+length(CAST(source AS BLOB))),0) FROM clips");
            using var reader=cmd.ExecuteReader(); reader.Read(); return new(reader.GetInt32(0),reader.GetInt32(1),reader.GetInt64(2));
        }
    }
    private ClipRecord CopyIndependent(ClipRecord item,string title,DateTimeOffset date,bool snippet)
    {
        ValidateMetadata(title,item.Source); Capacity(item.ByteCount+Metadata(title,item.Source));
        string id=Guid.NewGuid().ToString("D"); var copied=new List<string>();
        try
        {
            string? Copy(string? source,string folder)
            {
                if (source is null) return null;
                if (!Owned(source) || !File.Exists(source)) throw Missing(); RejectLink(source);
                string destination=Path.Combine(folder,id+Path.GetExtension(source));
                using (var input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read))
                {
                    if(input.Length>(PathComparer.Equals(folder,_assets)?MaximumImageBytes:MaximumTextBytes)) throw new ClipStoreException("Saved image exceeds its size limit.");
                    WritePrivate(destination,input);
                }
                copied.Add(destination); return destination;
            }
            string? asset=Copy(item.AssetPath,_assets),thumb=Copy(item.ThumbnailPath,_thumbnails);
            var record=item with { Id=id,Title=title,CapturedAt=date,ExpiresAt=snippet ? null : date+Retention,
                IsSnippet=snippet,AssetPath=asset,ThumbnailPath=thumb,IsParameterized=snippet && item.IsParameterized };
            Insert(record,null); return record;
        }
        catch { QueueCleanup([..copied]); throw; }
    }
    private void Capacity(long additional,int records=1)
    {
        if (records==0 && additional<=0) return;
        var stats=Stats();
        if ((long)stats.HistoryCount+stats.SnippetCount+records>MaximumRecords) throw new ClipStoreException("Local history has reached 10,000 items.");
        if (stats.Bytes+additional>MaximumStorageBytes) throw new ClipStoreException("Local storage is full (512 MiB). Delete items before adding more.");
    }
    private ClipRecord? Duplicate(string digest,ClipKind kind,DateTimeOffset date)
    {
        using var cmd=Command("SELECT id,digest FROM clips WHERE snippet=0 ORDER BY captured DESC,rowid DESC LIMIT 1");
        string? id=null,existing=null;
        using(var reader=cmd.ExecuteReader()) if(reader.Read()) { id=reader.GetString(0); existing=reader.IsDBNull(1)?null:reader.GetString(1); }
        if(existing!=digest || id is null) return null;
        var item=Record(id,date);
        return item is not null && item.Kind==kind && date>=item.CapturedAt && date-item.CapturedAt<=TimeSpan.FromSeconds(2) ? item : null;
    }
    private void Insert(ClipRecord item,string? digest) => Execute("INSERT INTO clips(id,kind,text,title,captured,expires,source,snippet,asset,thumbnail,bytes,digest,parameterized) VALUES(@id,@kind,@text,@title,@captured,@expires,@source,@snippet,@asset,@thumbnail,@bytes,@digest,@parameterized)",
        [("@id",item.Id),("@kind",KindText(item.Kind)),("@text",item.Text),("@title",item.Title),("@captured",Stamp(item.CapturedAt)),("@expires",item.ExpiresAt is {} e?Stamp(e):null),("@source",item.Source),("@snippet",item.IsSnippet?1:0),("@asset",item.AssetPath),("@thumbnail",item.ThumbnailPath),("@bytes",item.ByteCount),("@digest",digest),("@parameterized",item.IsParameterized?1:0)]);
    private void Remove(string condition,IReadOnlyList<(string,object?)> parameters)
    {
        var paths=new List<string>(); int count=0;
        using(var cmd=Command($"SELECT asset,thumbnail FROM clips WHERE {condition}",parameters))
        using(var reader=cmd.ExecuteReader()) while(reader.Read()) { count++; for(int i=0;i<2;i++) if(!reader.IsDBNull(i)) paths.Add(reader.GetString(i)); }
        if(count==0) return;
        Execute($"DELETE FROM clips WHERE {condition}",parameters);
        foreach(var path in paths) _pendingRemovals.Add(path);
        RetryRemovals();
    }
    private void QueueCleanup(params string[] paths)
    {
        foreach(var path in paths) _pendingRemovals.Add(path);
        try { RetryRemovals(); } catch(ClipStoreException) { } catch(IOException) { } catch(UnauthorizedAccessException) { }
    }
    private void RetryRemovals()
    {
        Exception? first=null;
        foreach(var path in _pendingRemovals.ToArray())
        {
            try { if(Owned(path) && (File.Exists(path) || new FileInfo(path).LinkTarget is not null)) File.Delete(path); _pendingRemovals.Remove(path); }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException) { first??=error; }
        }
        if(first is not null) throw new ClipStoreException("Some image files could not be removed. Cleanup will retry.",first);
    }
    private bool Owned(string path)
    {
        string full=Path.GetFullPath(path); string? parent=Path.GetDirectoryName(full);
        return (PathComparer.Equals(parent,_assets)||PathComparer.Equals(parent,_thumbnails)) && Guid.TryParse(Path.GetFileNameWithoutExtension(full),out _);
    }
    private void Reconcile()
    {
        var rows=new List<(string Id,bool Image,bool Snippet,string? Asset,string? Thumb)>();
        using(var cmd=Command("SELECT id,kind,snippet,asset,thumbnail FROM clips"))
        using(var reader=cmd.ExecuteReader()) while(reader.Read()) rows.Add((reader.GetString(0),reader.GetString(1)=="image",reader.GetBoolean(2),reader.IsDBNull(3)?null:reader.GetString(3),reader.IsDBNull(4)?null:reader.GetString(4)));
        var referenced=new HashSet<string>(PathComparer);
        foreach(var row in rows)
        {
            string? Rebase(string? stored,string folder)
            {
                if(stored is null) return null;
                if(!Guid.TryParse(row.Id,out _) || Path.GetFileNameWithoutExtension(stored)!=row.Id || Path.GetFileName(Path.GetDirectoryName(stored))!=Path.GetFileName(folder)) return stored;
                string candidate=Path.Combine(folder,Path.GetFileName(stored));
                if(!File.Exists(candidate)) return stored; RejectLink(candidate); return candidate;
            }
            string? asset=Rebase(row.Asset,_assets),thumb=Rebase(row.Thumb,_thumbnails);
            if(asset!=row.Asset||thumb!=row.Thumb) Execute("UPDATE clips SET asset=@asset,thumbnail=@thumb WHERE id=@id",[("@asset",asset),("@thumb",thumb),("@id",row.Id)]);
            foreach(string path in new[]{asset,thumb}.OfType<string>()) if(Owned(path)) referenced.Add(Path.GetFullPath(path));
            if(row.Image&&!row.Snippet&&(asset is null||!File.Exists(asset))) Delete(row.Id);
        }
        foreach(var folder in new[]{_assets,_thumbnails})
        {
            RejectLink(folder);
            foreach(string file in System.IO.Directory.EnumerateFiles(folder))
                if(Owned(file)&&!referenced.Contains(Path.GetFullPath(file))) File.Delete(file);
        }
    }
    private IReadOnlyList<ClipRecord> Fetch(string sql,IReadOnlyList<(string,object?)> parameters,CancellationToken token=default)
    {
        using var command=Command(sql,parameters); using var cancel=token.Register(command.Cancel); using var reader=command.ExecuteReader();
        var result=new List<ClipRecord>();
        while(reader.Read())
        {
            token.ThrowIfCancellationRequested();
            var kind=reader.GetString(1) switch { "text"=>ClipKind.Text,"image"=>ClipKind.Image,_=>throw new ClipStoreException("Invalid history kind.") };
            result.Add(new(reader.GetString(0),kind,reader.IsDBNull(2)?null:StrictUtf8.GetString(reader.GetFieldValue<byte[]>(2)),StrictUtf8.GetString(reader.GetFieldValue<byte[]>(3)),Date(reader.GetInt64(4)),reader.IsDBNull(5)?null:Date(reader.GetInt64(5)),StrictUtf8.GetString(reader.GetFieldValue<byte[]>(6)),reader.GetBoolean(7),reader.IsDBNull(8)?null:reader.GetString(8),reader.IsDBNull(9)?null:reader.GetString(9),reader.GetInt64(10),reader.GetBoolean(11)));
        }
        return result;
    }
    private SqliteCommand Command(string sql,IReadOnlyList<(string,object?)>? parameters=null,SqliteTransaction? transaction=null)
    {
        var command=_db.CreateCommand(); command.Transaction=transaction;
        if(parameters is not null) foreach(var (name,value) in parameters)
        {
            if(value is string text)
            {
                // Explicit UTF8 bytes avoid provider/native C-string truncation at NUL,
                // including mixed supplementary characters in larger text values.
                command.Parameters.AddWithValue(name,StrictUtf8.GetBytes(text));
                sql=Regex.Replace(sql,Regex.Escape(name)+@"\b",_=>"CAST("+name+" AS TEXT)",RegexOptions.CultureInvariant);
            }
            else command.Parameters.AddWithValue(name,value??DBNull.Value);
        }
        command.CommandText=sql;
        return command;
    }
    private void Execute(string sql,IReadOnlyList<(string,object?)>? parameters=null,SqliteTransaction? transaction=null)
    {
        _operationCancellation.ThrowIfCancellationRequested();
        using var command=Command(sql,parameters,transaction);
        using var registration=_operationCancellation.Register(command.Cancel);
        try { command.ExecuteNonQuery(); }
        catch(Exception) when(_operationCancellation.IsCancellationRequested) { throw new OperationCanceledException(_operationCancellation); }
    }
    private object? Scalar(string sql) { using var command=Command(sql); return command.ExecuteScalar(); }
    private static long Stamp(DateTimeOffset value)=>value.UtcTicks;
    private static DateTimeOffset Date(long ticks)=>new(ticks,TimeSpan.Zero);
    private static string KindText(ClipKind kind)=>kind==ClipKind.Text?"text":"image";
    private static int Utf8(string value)
    {
        try { return StrictUtf8.GetByteCount(value); }
        catch(EncoderFallbackException error) { throw new ClipStoreException("Text contains an invalid Unicode surrogate.", error); }
    }
    private static long Metadata(string title,string source)=>(long)Utf8(title)+Utf8(source);
    private static string Digest(byte[] data)=>Convert.ToHexString(SHA256.HashData(data));
    private static void ValidateText(string text)
    { if(Utf8(text)>MaximumTextBytes) throw new ClipStoreException("Text exceeds the 1 MiB item limit."); }
    private static void ValidateMetadata(string title,string source)
    { if(Utf8(title)>MaximumTextBytes||Utf8(source)>MaximumTextBytes) throw new ClipStoreException("Title or source exceeds the 1 MiB item limit."); }
    private static void ValidateSnippet(string title,string text)
    { ValidateText(text); ValidateMetadata(title,"Snippet"); if(string.IsNullOrWhiteSpace(title)||string.IsNullOrWhiteSpace(text)) throw new ClipStoreException("A snippet needs a title and content."); }
    private static string TitleFor(string text)
    {
        var title=new StringBuilder(); int count=0;
        var elements=StringInfo.GetTextElementEnumerator(text);
        while(elements.MoveNext())
        {
            string element=elements.GetTextElement();
            if(element.IndexOfAny(['\r','\n','\u0085','\u2028','\u2029'])>=0)
            { if(count>0) break; continue; }
            title.Append(element); if(++count==120) break;
        }
        return title.ToString();
    }
    private static byte[]? PreviewBytes(byte[]? bytes,int limit)
    {
        if(bytes is null) return null;
        int offset=0,count=0;
        while(offset<bytes.Length&&count<Math.Max(0,limit))
        {
            if(Rune.DecodeFromUtf8(bytes.AsSpan(offset),out _,out int consumed)!=OperationStatus.Done)
                throw new ClipStoreException("Saved text contains invalid UTF8.");
            offset+=consumed;count++;
        }
        return offset==bytes.Length?bytes:bytes.AsSpan(0,offset).ToArray();
    }
    private static ClipStoreException Missing()=>new("This item has expired or is no longer available.");
    private static void RejectLink(string path)
    {
        var info=new FileInfo(path);
        if(info.LinkTarget is not null || (File.Exists(path)||System.IO.Directory.Exists(path)) && (File.GetAttributes(path)&FileAttributes.ReparsePoint)!=0)
            throw new ClipStoreException("ClipDiary-owned storage paths cannot be symbolic links or reparse points.");
    }
    private static void MakePrivate(string path,bool directory)
    {
        if(OperatingSystem.IsWindows()) MakePrivateWindows(path,directory);
        else File.SetUnixFileMode(path,directory ? UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute : UnixFileMode.UserRead|UnixFileMode.UserWrite);
    }
    [SupportedOSPlatform("windows")]
    private static void MakePrivateWindows(string path,bool directory)
    {
        using var identity=WindowsIdentity.GetCurrent();
        var user=identity.User??throw new ClipStoreException("Cannot determine the current Windows user.");
        if(directory)
        {
            var acl=new DirectorySecurity(); acl.SetOwner(user); acl.SetAccessRuleProtection(true,false);
            acl.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,InheritanceFlags.ContainerInherit|InheritanceFlags.ObjectInherit,PropagationFlags.None,AccessControlType.Allow));
            new DirectoryInfo(path).SetAccessControl(acl);
        }
        else
        {
            var acl=new FileSecurity(); acl.SetOwner(user); acl.SetAccessRuleProtection(true,false);
            acl.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,AccessControlType.Allow)); new FileInfo(path).SetAccessControl(acl);
        }
    }
    private void WritePrivate(string destination,byte[] data) { using var stream=new MemoryStream(data,false); WritePrivate(destination,stream); }
    private void WritePrivate(string destination,Stream source)
    {
        string folder=Path.GetDirectoryName(destination)!; RejectLink(folder);
        if(!Owned(destination)) throw new ClipStoreException("Invalid owned image path.");
        string temporary=Path.Combine(folder,Guid.NewGuid().ToString("D")+".tmp");
        try
        {
            using(var output=new FileStream(temporary,FileMode.CreateNew,FileAccess.Write,FileShare.None,64*1024,FileOptions.WriteThrough)) { MakePrivate(temporary,false); var buffer=new byte[64*1024];
                int read; while((read=source.Read(buffer))>0) { _operationCancellation.ThrowIfCancellationRequested(); output.Write(buffer,0,read); }
                _operationCancellation.ThrowIfCancellationRequested(); output.Flush(true); }
            File.Move(temporary,destination,false);
        }
        finally
        {
            if(File.Exists(temporary))
            {
                try { File.Delete(temporary); }
                catch(Exception error) when(error is IOException or UnauthorizedAccessException)
                {
                    // Never mask the original write/cancellation error or lose the
                    // only reference to a sensitive partial image. Purge retries it.
                    _pendingRemovals.Add(temporary);
                }
            }
        }
    }
    private void EnsureOpen() { ObjectDisposedException.ThrowIf(_disposed,this); }
    public void Dispose() { lock(_gate) { if(_disposed) return; _disposed=true; _db.Dispose(); } }
}
