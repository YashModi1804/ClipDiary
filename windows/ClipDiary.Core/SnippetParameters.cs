using System.Text;
using System.Text.RegularExpressions;

namespace ClipDiary.Core;

/// <summary>Literal single-pass substitution. Empty/missing values retain the original placeholder.</summary>
public static partial class SnippetParameters
{
    [GeneratedRegex(@"<([\p{L}\p{N}_-]+)>", RegexOptions.CultureInvariant, 1000)]
    private static partial Regex Pattern();
    public static IReadOnlyList<string> Names(string text)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var result = new List<string>();
        foreach (Match match in Pattern().Matches(text))
            if (seen.Add(match.Groups[1].Value)) result.Add(match.Groups[1].Value);
        return result;
    }
    public static string Render(string text, IReadOnlyDictionary<string, string>? values = null,
        int maximumBytes = ClipStore.MaximumTextBytes)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(maximumBytes);
        var output = new StringBuilder(Math.Min(text.Length, maximumBytes));
        int position = 0, bytes = 0;
        void Append(ReadOnlySpan<char> value)
        {
            int size = Encoding.UTF8.GetByteCount(value);
            if (size > maximumBytes - bytes) throw new ClipStoreException("Expanded text exceeds the 1 MiB item limit.");
            bytes += size;
            output.Append(value);
        }
        foreach (Match match in Pattern().Matches(text))
        {
            Append(text.AsSpan(position, match.Index - position));
            var name = match.Groups[1].Value;
            var replacement = values is not null && values.TryGetValue(name, out var value) ? value : null;
            Append(string.IsNullOrEmpty(replacement) ? match.Value.AsSpan() : replacement.AsSpan());
            position = match.Index + match.Length;
        }
        Append(text.AsSpan(position));
        return output.ToString();
    }
}
