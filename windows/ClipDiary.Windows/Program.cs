using System.Security.Principal;
using System.Windows;
using ClipDiary.Core;

namespace ClipDiary.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        if (args.Contains("--windows-checks", StringComparer.Ordinal))
        {
            int reportIndex = Array.IndexOf(args, "--report");
            StreamWriter? report = null;
            if (reportIndex >= 0)
            {
                if (reportIndex + 1 >= args.Length) return 2;
                string reportPath = Path.GetFullPath(args[reportIndex + 1]);
                Directory.CreateDirectory(Path.GetDirectoryName(reportPath)!);
                report = new StreamWriter(reportPath, false) { AutoFlush = true };
                var synchronized = TextWriter.Synchronized(report);
                Console.SetOut(synchronized); Console.SetError(synchronized);
            }
            app.Startup += async (_, _) =>
            {
                try { app.Shutdown(await WindowsChecks.RunAsync()); }
                catch (Exception error) { Console.Error.WriteLine("Windows checks failed: " + error.Message); app.Shutdown(1); }
            };
            try { return app.Run(); }
            finally { report?.Dispose(); }
        }
        var user = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        var name = @"Local\ClipDiary-" + user;
        using var instance = new Mutex(true, name, out bool first);
        using var signal = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-show");
        using var quitSignal = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-quit");
        if (!first)
        {
            if (args.Contains("--quit", StringComparer.Ordinal))
            {
                quitSignal.Set();
                bool acquired;
                try { acquired = instance.WaitOne(TimeSpan.FromSeconds(15)); }
                catch (AbandonedMutexException) { acquired = true; }
                if (acquired) instance.ReleaseMutex();
                return acquired ? 0 : 1;
            }
            if (!args.Contains("--background", StringComparer.Ordinal)) signal.Set();
            return 0;
        }
        if (args.Contains("--quit", StringComparer.Ordinal)) { instance.ReleaseMutex(); return 0; }
        AppController? controller = null;
        RegisteredWaitHandle? registration = null;
        RegisteredWaitHandle? quitRegistration = null;
        app.Startup += async (_, _) =>
        {
            try
            {
                string directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClipDiary");
                var store = await Task.Run(() => new ClipStore(directory));
                controller = new AppController(store, directory); controller.Start();
                registration = ThreadPool.RegisterWaitForSingleObject(signal,
                    (_, _) => app.Dispatcher.BeginInvoke(controller.ShowHistory), null, Timeout.Infinite, false);
                quitRegistration = ThreadPool.RegisterWaitForSingleObject(quitSignal,
                    (_, _) => app.Dispatcher.BeginInvoke(controller.RequestQuit), null, Timeout.Infinite, false);
                if (!args.Contains("--background", StringComparer.Ordinal)) controller.ShowHistory();
            }
            catch (Exception error)
            {
                MessageBox.Show("ClipDiary could not start. Your saved data has not been reset.\n\n" + error.Message,
                    "ClipDiary", MessageBoxButton.OK, MessageBoxImage.Error);
                if (controller is not null) await controller.DisposeAsync();
                app.Shutdown(1);
            }
        };
        app.Exit += (_, _) => { registration?.Unregister(null); quitRegistration?.Unregister(null); };
        try { return app.Run(); }
        finally { instance.ReleaseMutex(); }
    }
}
