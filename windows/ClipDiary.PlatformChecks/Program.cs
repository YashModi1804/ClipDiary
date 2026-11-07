using System.Text;
using ClipDiary.Windows.Platform;

int assertions = 0;
void Check(bool value, string name)
{ if (!value) throw new InvalidOperationException(name); assertions++; }
var now = DateTimeOffset.UtcNow;
var baseline = now - TimeSpan.FromHours(96);
Check(!CapturePolicy.EligibleScreenshot(baseline, baseline, now), "Exact expiry/baseline excluded");
Check(CapturePolicy.EligibleScreenshot(baseline.AddTicks(1), baseline, now), "Fresh boundary eligible");
Check(!CapturePolicy.EligibleScreenshot(now.AddTicks(1), baseline, now), "Future screenshot excluded");
Check(CapturePolicy.EligibleScreenshot(now, baseline, now), "Current screenshot eligible");
foreach (var dimensions in new[] { (0, 1), (1, 0), (-1, 200), (int.MaxValue, int.MaxValue), (10001, 5000) })
    Check(!CapturePolicy.ValidDimensions(dimensions.Item1, dimensions.Item2), "Invalid dimensions rejected");
Check(CapturePolicy.ValidDimensions(10000, 5000), "Exact pixel cap accepted");
Check(CapturePolicy.ValidDimensions(1, 1), "Small image accepted");
Check(!CapturePolicy.ValidText("  \n\t"), "Blank text skipped");
var exact = new string('é', CapturePolicy.MaximumTextBytes / 2);
Check(CapturePolicy.ValidText(exact), "UTF8 exact byte cap accepted");
Check(!CapturePolicy.ValidText(exact + "x"), "UTF8 oversized text rejected");
Check(CapturePolicy.ValidText("embedded\0value🙂"), "Unicode and null text retained");
foreach (var extension in new[] { ".png", ".PNG", ".JpG", ".jpeg", ".bmp", ".tif", ".tiff" })
    Check(CapturePolicy.IsImagePath("synthetic" + extension), "Supported extension");
foreach (var extension in new[] { ".txt", ".exe", ".png.exe", "" })
    Check(!CapturePolicy.IsImagePath("synthetic" + extension), "Unsupported extension");
byte[] signature = [137,80,78,71,13,10,26,10];
byte[] end = [0,0,0,0,73,69,78,68,174,66,96,130];
Check(!CapturePolicy.IsPngComplete(signature), "PNG missing IEND rejected");
Check(CapturePolicy.IsPngComplete(signature.Concat(end).ToArray()), "Terminal PNG chunk present");
Check(CapturePolicy.IsPngComplete([0x49,0x49,0x2A,0]), "Non-PNG routed to codec validation");
for (int failure = 1; failure < 50; failure++)
{ var delay = CapturePolicy.RetryDelay(failure); Check(delay >= TimeSpan.FromSeconds(1) && delay <= TimeSpan.FromSeconds(30), "Retry delay bounded"); }
Check(CapturePolicy.RetryDelay(1) < CapturePolicy.RetryDelay(2), "Retries back off");
Check(CapturePolicy.NormalizeProcess(" Bitwarden.EXE ") == "bitwarden", "Process names normalized");
Check(CapturePolicy.NormalizeProcess(@"C:\Apps\Secure.App.EXE") == "secure.app", "Windows paths normalize on every test host");
Check(CapturePolicy.NormalizeProcess("secure.app") == "secure.app", "Dotted process names keep their suffix");
foreach (uint state in new uint[] { 1, 2, 9 })
    Check(CapturePolicy.IsLocallyAvailableCloudItem(0x400, state), "Local hydrated cloud files or sync roots remain eligible");
foreach (uint state in new uint[] { 0, uint.MaxValue, 0x11, 0x21 })
    Check(!CapturePolicy.IsLocallyAvailableCloudItem(0x400, state), "Unknown or partial cloud items rejected");
foreach (uint attributes in new uint[] { 0x1400, 0x40400, 0x400400 })
    Check(!CapturePolicy.IsLocallyAvailableCloudItem(attributes, 9), "Offline or recall-required items rejected");
Console.WriteLine($"PASS: {assertions} portable capture-policy assertions (retention, image bounds, UTF8, PNG completion, retries and exclusions).");
