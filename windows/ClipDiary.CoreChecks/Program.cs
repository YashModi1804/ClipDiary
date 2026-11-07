using System.Diagnostics;
using System.Text;
using ClipDiary.Core;
using Microsoft.Data.Sqlite;

static class Checks
{
    private static int _assertions;
    private static void Require(bool condition,string message)
    { _assertions++; if(!condition) throw new Exception("FAIL: "+message); }
    private static void Throws<T>(Action action,string message) where T:Exception
    { try { action(); } catch(T) { _assertions++; return; } throw new Exception("FAIL: "+message); }
    private static string Temp()=>Path.Combine(Path.GetTempPath(),"clipdiary-core-checks-"+Guid.NewGuid().ToString("N"));
    private static readonly byte[] Image=Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=");
    private static readonly DateTimeOffset Now=DateTimeOffset.UtcNow;
    private static void Raw(string folder,string sql)
    {
        using var db=new SqliteConnection(new SqliteConnectionStringBuilder{DataSource=Path.Combine(folder,"history.sqlite3"),Pooling=false}.ToString());
        db.Open(); using var cmd=db.CreateCommand(); cmd.CommandText=sql;cmd.ExecuteNonQuery();
    }
    private static T RawScalar<T>(string folder,string sql)
    {
        using var db=new SqliteConnection(new SqliteConnectionStringBuilder{DataSource=Path.Combine(folder,"history.sqlite3"),Pooling=false}.ToString());
        db.Open();using var cmd=db.CreateCommand();cmd.CommandText=sql;return (T)Convert.ChangeType(cmd.ExecuteScalar()!,typeof(T));
    }
    public static async Task<int> Main(string[] arguments)
    {
        string root=Temp();System.IO.Directory.CreateDirectory(root);
        try
        {
            TextRetentionAndSnippets(Path.Combine(root,"text"));
            ImageDurabilityAndMoves(Path.Combine(root,"images"));
            ParametersAndUnicode(Path.Combine(root,"parameters"));
            CapacityAndExpiry(Path.Combine(root,"capacity"));
            PrivateCleanupAndRollback(Path.Combine(root,"private"));
            await CancellationAndSerialization(Path.Combine(root,"async"));
            SchemaAndLinks(Path.Combine(root,"schema"));
            if(arguments.Contains("--stress")) Stress(Path.Combine(root,"stress"));
            Console.WriteLine($"PASS: {_assertions} Windows portable core assertions; no clipboard, network or user history accessed.");
            return 0;
        }
        catch(Exception error){ Console.Error.WriteLine(error);return 1; }
        finally { try {System.IO.Directory.Delete(root,true);}catch(IOException){}catch(UnauthorizedAccessException){} }
    }
    private static void TextRetentionAndSnippets(string folder)
    {
        using var store=new ClipStore(folder);
        var text=store.AddText("  literal\0text\n尾  ","Original\0source",Now)!;
        Require(store.Record(text.Id,Now)!.Text==text.Text,"embedded NUL/whitespace survive persistence");
        Require(store.Record(text.Id,Now)!.Source==text.Source,"source NUL survives persistence");
        Require(store.Records(previewLimit:4096).Single().Text==text.Text,"preview UDF preserves text beyond embedded NUL");
        Throws<ClipStoreException>(()=>store.AddText("invalid \uD800","Test"),"unpaired UTF16 surrogate rejected before persistence");
        var duplicate=store.AddText(text.Text!,"Original\0source",Now.AddSeconds(1))!;
        Require(duplicate.Id==text.Id&&duplicate.ExpiresAt==text.ExpiresAt,"consecutive passive dedup does not extend retention");
        store.SaveSnippet(text.Id);
        var snippet=store.Records(snippets:true).Single();
        Require(snippet.Id!=text.Id&&snippet.ExpiresAt is null&&snippet.CapturedAt==text.CapturedAt,"snippet is independent and preserves original capture time");
        store.UpdateSnippet(snippet.Id,"Edited\0title","changed");
        Require(store.Record(text.Id,Now)!.Text==text.Text,"editing snippet does not mutate source history");
        Require(store.Record(text.Id,Now+ClipStore.Retention) is null,"exact96h expiry hidden even before purge");
        store.Purge(Now+ClipStore.Retention);
        Require(store.Stats().HistoryCount==0&&store.Stats().SnippetCount==1,"purge preserves snippets");
        var snippetCopy=store.Recopy(snippet.Id,now:Now.AddHours(1));
        Require(snippetCopy.Id!=snippet.Id&&!snippetCopy.IsSnippet&&snippetCopy.Text=="changed","copying snippet creates new history");
        Require(store.Record(snippet.Id)!.CapturedAt==snippet.CapturedAt,"copying snippet keeps snippet timestamp");
        var newer=store.AddText("newer","Another",Now.AddHours(2))!;
        long bytes=store.Stats().Bytes;
        var promoted=store.Recopy(snippetCopy.Id,now:Now.AddHours(2));
        Require(store.Records().First().Id==promoted.Id,"recopy becomes latest even equal timestamps");
        Require(promoted.Id==snippetCopy.Id&&promoted.Source==snippetCopy.Source&&store.Stats().Bytes==bytes,"promotion preserves publicID/provenance/storage");
        Require(promoted.ExpiresAt==Now.AddHours(2)+ClipStore.Retention,"promotion resets exactly96h");
        Throws<ClipStoreException>(()=>store.Recopy(newer.Id,now:newer.ExpiresAt),"expired recopy rejected");
        var expired=store.AddText("expired","Test",Now-ClipStore.Retention-TimeSpan.FromMinutes(1))!;
        Throws<ClipStoreException>(()=>store.SaveSnippet(expired.Id),"expired history cannot become snippet");
        store.ClearHistory();Require(store.Stats().SnippetCount==1,"clear history preserves snippets");
    }
    private static void ImageDurabilityAndMoves(string folder)
    {
        string original=Path.Combine(folder,"Original"),moved=Path.Combine(folder,"Moved");
        ClipRecord image,snippet;
        using(var store=new ClipStore(original))
        {
            image=store.AddImage(Image,Image,"png","Screenshot","Screenshot folder",Now,deduplicate:false)!;
            store.SaveSnippet(image.Id);snippet=store.Records(snippets:true).Single();
            Require(image.AssetPath!=snippet.AssetPath&&image.ThumbnailPath!=snippet.ThumbnailPath,"image snippet owns independent files");
            long before=store.Stats().Bytes;
            var promoted=store.Recopy(image.Id,now:Now.AddSeconds(5));
            Require(promoted.AssetPath==image.AssetPath&&store.Stats().Bytes==before,"image promotion has no asset copies or size growth");
            var copy=store.Recopy(snippet.Id,now:Now.AddSeconds(6));
            Require(copy.AssetPath!=snippet.AssetPath&&File.ReadAllBytes(copy.AssetPath!).SequenceEqual(Image),"image snippet recopy has correct independent bytes");
            store.Delete(copy.Id);Require(File.Exists(snippet.AssetPath),"deleting copied history leaves snippet image");
        }
        System.IO.Directory.Move(original,moved);
        using(var store=new ClipStore(moved))
        {
            var restored=store.Record(snippet.Id)!;
            Require(restored.AssetPath!.StartsWith(store.DirectoryPath,StringComparison.Ordinal)&&File.ReadAllBytes(restored.AssetPath).SequenceEqual(Image),"moving data directory retains image snippet bytes");
            store.Purge(Now.AddSeconds(5)+ClipStore.Retention);
            Require(store.Record(image.Id,Now.AddSeconds(5)+ClipStore.Retention) is null&&!File.Exists(Path.Combine(moved,"Assets",Path.GetFileName(image.AssetPath!))),"expired image history file removed");
            Require(File.Exists(restored.AssetPath)&&File.Exists(restored.ThumbnailPath),"snippet originals/thumbnails survive source expiry");
            Throws<ClipStoreException>(()=>store.AddImage(Image,Image,"../bad","x","x"),"unsafe image extension rejected");
            var first=store.AddImage(Image,Image,"png","One","Folder",deduplicate:false)!;
            var second=store.AddImage(Image,Image,"png","Two","Folder",deduplicate:false)!;
            Require(first.Id!=second.Id,"intentional identical screenshot events remain distinct");
        }
    }
    private static void ParametersAndUnicode(string folder)
    {
        using var store=new ClipStore(folder);
        string template="run <instance> <instance> <region> <名>\0tail";
        store.CreateSnippet("Template",template);
        var snippet=store.Records(snippets:true).Single();store.SetParameterized(snippet.Id,true);
        var rendered=store.Recopy(snippet.Id,new Dictionary<string,string>{{"instance","PROD$1\\path <region>"},{"region",""},{"名","名字"}});
        Require(rendered.Text=="run PROD$1\\path <region> PROD$1\\path <region> <region> 名字\0tail","parameters are Unicode/literal/singlepass and blank retains placeholder");
        Require(store.Record(snippet.Id)!.Text==template&&store.Record(snippet.Id)!.IsParameterized,"template remains immutable opted in");
        Require(SnippetParameters.Names(template).SequenceEqual(new[]{"instance","region","名"}),"parameter names unique in discovery order");
        int before=store.Stats().HistoryCount;
        Throws<ClipStoreException>(()=>store.Recopy(snippet.Id,new Dictionary<string,string>{{"instance",new string('x',ClipStore.MaximumTextBytes)}}),"expanded byte limit enforced");
        Require(store.Stats().HistoryCount==before,"failed expansion creates no history");
        var unicode=store.AddText("ÉCOLE Привет %_\\ (literal) [x]\0tail 👩🏽‍💻","Source")!;
        foreach(string query in new[]{"école","привет","%_\\","(literal)","[x]","\0tail","👩"})
            Require(store.Records(query).Any(x=>x.Id==unicode.Id),"Unicode/canonical/literal search: "+query);
        Require(!store.Records("%notpresent").Any(),"search percent is literal");
        var decomposed=store.AddText("e\u0301","ZZZ",Now.AddMinutes(1))!;
        Require(store.Records("é").Any(x=>x.Id==decomposed.Id),"composed and decomposed accents search equally");
        var preview=store.Records(previewLimit:10).First(x=>x.Id==unicode.Id);
        string expected=string.Concat(unicode.Text!.EnumerateRunes().Take(10).Select(x=>x.ToString()));
        Require(preview.Text==expected&&store.Record(unicode.Id)!.Text==unicode.Text,"scalar preview bounded; full lookup untouched");
        string literalQuery=new('x',2000);
        var longLiteral=store.AddText(literalQuery,"Long literal",Now.AddMinutes(2))!;
        Require(store.Records(literalQuery).Any(x=>x.Id==longLiteral.Id),"long literal query does not hit regex automaton size limits");
        string cluster="👩🏽‍💻";var clustered=store.AddText(string.Concat(Enumerable.Repeat(cluster,130)),"Grapheme title",Now.AddMinutes(3))!;
        Require(System.Globalization.StringInfo.ParseCombiningCharacters(clustered.Title).Length==120,"autogenerated title preserves120complete graphemes");
        string scalarText=string.Concat(Enumerable.Repeat("😀e\u0301\0",3000));
        var scalarItem=store.AddText(scalarText,"Scalar preview",Now.AddMinutes(4))!;
        string scalarExpected=string.Concat(scalarText.EnumerateRunes().Take(4096).Select(x=>x.ToString()));
        Require(RawScalar<long>(folder,$"SELECT length(CAST(text AS BLOB)) FROM clips WHERE id='{scalarItem.Id}'")==Encoding.UTF8.GetByteCount(scalarText),"full Unicode/NUL payload persisted in SQLite");
        Require(store.Record(scalarItem.Id)!.Text==scalarText,"full Unicode/NUL record lookup complete");
        var actualScalar=store.Records(previewLimit:4096).First(x=>x.Id==scalarItem.Id).Text!;
        Require(actualScalar==scalarExpected,$"largeUTF8preview preserves scalar/NULboundaries (actual chars{actualScalar.Length}/runes{actualScalar.EnumerateRunes().Count()}, expected chars{scalarExpected.Length}/runes{scalarExpected.EnumerateRunes().Count()})");
        store.SetParameterized(snippet.Id,false);
        Require(store.Recopy(snippet.Id).Text==template,"disabled parameterization stays literal");
        Throws<ClipStoreException>(()=>store.SetParameterized(rendered.Id,true),"history cannot opt into parameterization");
    }
    private static void CapacityAndExpiry(string folder)
    {
        using var store=new ClipStore(folder);
        store.CreateSnippet("Protected","seed");var seed=store.Records(snippets:true).Single();
        string oversized=new('x',ClipStore.MaximumTextBytes+1);
        Throws<ClipStoreException>(()=>store.CreateSnippet(oversized,"x"),"title limit");
        Throws<ClipStoreException>(()=>store.AddText("x",oversized),"source limit");
        Throws<ClipStoreException>(()=>store.AddText(oversized,"x"),"text limit");
        Throws<ClipStoreException>(()=>store.AddImage(new byte[ClipStore.MaximumImageBytes+1],Image,"png","x","x"),"encoded image limit");
        long filler=ClipStore.MaximumStorageBytes-store.Stats().Bytes-2;
        Raw(folder,$"INSERT INTO clips VALUES('filler','text','x','f',{Now.UtcTicks},{(Now+ClipStore.Retention).UtcTicks},'s',0,NULL,NULL,{filler},NULL,0)");
        Throws<ClipStoreException>(()=>store.CreateSnippet("new","x"),"metadata budget enforced without allocating512MiB");
        Throws<ClipStoreException>(()=>store.UpdateSnippet(seed.Id,"Much larger title","seed"),"title growth budget enforced");
        store.UpdateSnippet(seed.Id,"S","s");Require(store.Record(seed.Id)!.Text=="s","shrinking edit allowed to recover capacity");
        store.DeleteAll();
        Raw(folder,$"WITH RECURSIVE s(n) AS(VALUES(1) UNION ALL SELECT n+1 FROM s WHERE n<10000) INSERT INTO clips SELECT 'expired-'||n,'text','old','old',{(Now-ClipStore.Retention-TimeSpan.FromMinutes(1)).UtcTicks},{Now.AddMinutes(-1).UtcTicks},'s',0,NULL,NULL,3,NULL,0 FROM s");
        store.CreateSnippet("New","new");Require(store.Stats().HistoryCount==0&&store.Stats().SnippetCount==1,"expired rows do not consume snippet capacity");
        Raw(folder,$"WITH RECURSIVE s(n) AS(VALUES(1) UNION ALL SELECT n+1 FROM s WHERE n<9999) INSERT INTO clips SELECT 'live-'||n,'text','live','live',{Now.UtcTicks},{(Now+ClipStore.Retention).UtcTicks},'s',0,NULL,NULL,4,NULL,0 FROM s");
        Throws<ClipStoreException>(()=>store.AddText("overflow","s"),"10k record cap enforced");
        var promoted=store.Recopy("live-1");Require(promoted.Id=="live-1"&&store.Stats().HistoryCount==9999,"promotion allowed at record cap");
        string snippetId=store.Records(snippets:true).Single().Id;
        Throws<ClipStoreException>(()=>store.Recopy(snippetId),"independent snippet history requires record capacity");
    }
    private static void PrivateCleanupAndRollback(string folder)
    {
        using var store=new ClipStore(folder);
        Raw(folder,"CREATE TRIGGER reject_image BEFORE INSERT ON clips WHEN NEW.kind='image' BEGIN SELECT RAISE(ABORT,'fixture insert failure'); END");
        Throws<SqliteException>(()=>store.AddImage(Image,Image,"png","Rollback","s"),"injected image SQL failure surfaces");
        Require(!System.IO.Directory.EnumerateFiles(Path.Combine(folder,"Assets")).Any()&&!System.IO.Directory.EnumerateFiles(Path.Combine(folder,"Thumbnails")).Any(),"failed SQL insert cleans both written assets");
        Raw(folder,"DROP TRIGGER reject_image");
        string sentinel="DELETE_SENTINEL_"+Guid.NewGuid().ToString("N");var text=store.AddText(sentinel,"Test")!;
        Require(Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(folder,"history.sqlite3"))).Contains(sentinel,StringComparison.Ordinal),"sentinel actually persisted before delete");
        store.Delete(text.Id);
        Require(!Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(folder,"history.sqlite3"))).Contains(sentinel,StringComparison.Ordinal),"secure_delete removes active database sentinel bytes");
        Require(!File.Exists(Path.Combine(folder,"history.sqlite3-journal"))&&!File.Exists(Path.Combine(folder,"history.sqlite3-wal")),"DELETE journal leaves no surviving rollback/WAL file");
        if(!OperatingSystem.IsWindows())
        {
            Require(File.GetUnixFileMode(Path.Combine(folder,"history.sqlite3"))==(UnixFileMode.UserRead|UnixFileMode.UserWrite),"database is0600 onUnix test host");
            var image=store.AddImage(Image,Image,"png","Retry","s")!;string assets=Path.Combine(folder,"Assets");
            File.SetUnixFileMode(assets,UnixFileMode.UserRead|UnixFileMode.UserExecute);
            try {Throws<ClipStoreException>(()=>store.Delete(image.Id),"permission denial reported");}
            finally {File.SetUnixFileMode(assets,UnixFileMode.UserRead|UnixFileMode.UserWrite|UnixFileMode.UserExecute);}
            store.Purge();Require(!File.Exists(image.AssetPath)&&!File.Exists(image.ThumbnailPath),"failed deletion retried without restart");
        }
    }
    private static async Task CancellationAndSerialization(string folder)
    {
        using var store=new ClipStore(folder);
        var tasks=Enumerable.Range(0,40).Select(index=>store.RunAsync(s=>s.AddText("parallel-"+index,"Async",Now.AddSeconds(index*3))));
        await Task.WhenAll(tasks);Require(store.Stats().HistoryCount==40,"concurrent worker calls serialize without lost writes");
        using var canceled=new CancellationTokenSource();
        try {await store.RunAsync(s=>{canceled.Cancel();return s.AddText("must not commit","Async");},canceled.Token);throw new Exception("FAIL cancellation committed");}
        catch(OperationCanceledException){_assertions++;}
        Require(!store.Records().Any(x=>x.Text=="must not commit"),"cancellation checked inside lock before SQL mutation");
        using var searchCancellation=new CancellationTokenSource();searchCancellation.Cancel();
        Throws<OperationCanceledException>(()=>store.Records("parallel",cancellationToken:searchCancellation.Token),"search cancellation honored");
    }
    private static void SchemaAndLinks(string folder)
    {
        System.IO.Directory.CreateDirectory(folder);
        using(var store=new ClipStore(folder)){store.CreateSnippet("Keep","preserved");}
        Raw(folder,"PRAGMA user_version=99");
        Throws<ClipStoreException>(()=>{using var ignored=new ClipStore(folder);},"newer schema rejected");
        Require(RawScalar<long>(folder,"PRAGMA user_version")==99,"newer version marker unchanged");
        if(!OperatingSystem.IsWindows())
        {
            string external=Temp(),linked=Temp();System.IO.Directory.CreateDirectory(external);System.IO.Directory.CreateDirectory(linked);
            try
            {
                Raw(external,"CREATE TABLE unrelated(value TEXT);INSERT INTO unrelated VALUES('keep')");
                File.CreateSymbolicLink(Path.Combine(linked,"history.sqlite3"),Path.Combine(external,"history.sqlite3"));
                Throws<ClipStoreException>(()=>{using var ignored=new ClipStore(linked);},"linked database rejected");
                Require(RawScalar<long>(external,"PRAGMA user_version")==0,"unrelated linked database not migrated");
                File.Delete(Path.Combine(linked,"history.sqlite3"));
                string sentinel=Path.Combine(external,"keep.txt");File.WriteAllText(sentinel,"keep");
                if(System.IO.Directory.Exists(Path.Combine(linked,"Assets"))) System.IO.Directory.Delete(Path.Combine(linked,"Assets"));
                System.IO.Directory.CreateSymbolicLink(Path.Combine(linked,"Assets"),external);
                Throws<ClipStoreException>(()=>{using var ignored=new ClipStore(linked);},"linked asset folder rejected");
                Require(File.ReadAllText(sentinel)=="keep","external sentinel untouched");
            }
            finally{System.IO.Directory.Delete(linked,true);System.IO.Directory.Delete(external,true);}
        }
    }
    private static void Stress(string folder)
    {
        using var store=new ClipStore(folder);
        string text="payload-marker "+new string('x',32*1024-15);long start=Stopwatch.GetTimestamp();
        for(int index=0;index<256;index++) store.AddText(text+index,"Stress",Now.AddSeconds(index*3));
        double inserts=Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        start=Stopwatch.GetTimestamp();var full=store.Records();double fullMs=Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        start=Stopwatch.GetTimestamp();var preview=store.Records(previewLimit:4096);double previewMs=Stopwatch.GetElapsedTime(start).TotalMilliseconds;
        long fullBytes=full.Sum(x=>Encoding.UTF8.GetByteCount(x.Text!)),previewBytes=preview.Sum(x=>Encoding.UTF8.GetByteCount(x.Text!));
        Require(full.Count==256&&preview.Count==256&&previewBytes<fullBytes,"stress bounded preview retains fewer payload bytes");
        start=Stopwatch.GetTimestamp();Require(store.Records("PAYLOAD-MARKER",previewLimit:4096).Count==256,"stress case-insensitive fullcontent search");
        Console.WriteLine($"STRESS:256x32KiB inserts{inserts:F1}ms full{fullMs:F1}ms/{fullBytes}B preview{previewMs:F1}ms/{previewBytes}B search{Stopwatch.GetElapsedTime(start).TotalMilliseconds:F1}ms");
    }
}
