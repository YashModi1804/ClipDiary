using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace ClipDiary.Windows.Platform;

// One shared worker bounds decoded-image memory across both capture sources.
internal sealed class CapturePipeline : IDisposable
{
    private readonly SemaphoreSlim imageWorker = new(1, 1);
    private readonly SemaphoreSlim delivery = new(1, 1);
    private readonly object arrivalsGate = new();
    private readonly List<Arrival> arrivals = [];
    private int queued;
    private int textQueued;
    private bool disposed;
    private sealed record Arrival(string Digest, bool File, DateTimeOffset Time, DateTimeOffset Expires);
    internal int Queued => Volatile.Read(ref queued);
    internal bool Queue(CaptureSession session, Func<CancellationToken, Task> action, CancellationToken token)
    {
        if (disposed || !session.CanCapture || token.IsCancellationRequested) return false;
        if (Interlocked.Increment(ref queued) > 3) { Interlocked.Decrement(ref queued); return false; }
        _ = Task.Run(async () =>
        {
            bool entered = false;
            try
            {
                await imageWorker.WaitAsync(token).ConfigureAwait(false);
                entered = true;
                token.ThrowIfCancellationRequested();
                await action(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { }
            finally { if (entered) imageWorker.Release(); Interlocked.Decrement(ref queued); }
        });
        return true;
    }
    internal async Task<bool> Deliver(CaptureSession session, ClipboardPayload payload, bool file, Func<ClipboardPayload, CancellationToken, Task<bool>> callback, CancellationToken token)
    {
        await delivery.WaitAsync(token).ConfigureAwait(false);
        try
        {
            token.ThrowIfCancellationRequested();
            if (!session.CanCapture) return false;
            lock (arrivalsGate)
            {
                arrivals.RemoveAll(a => DateTimeOffset.UtcNow - a.Time > TimeSpan.FromSeconds(3) || a.Expires <= DateTimeOffset.UtcNow);
                var paired = arrivals.FindIndex(a => a.File != file && a.Digest == payload.Digest && payload.IsImage);
                if (paired >= 0) { arrivals.RemoveAt(paired); return true; }
            }
            if (!await callback(payload, token).ConfigureAwait(false)) return false;
            token.ThrowIfCancellationRequested();
            if (payload.IsImage)
            {
                lock (arrivalsGate)
                {
                    arrivals.Add(new Arrival(payload.Digest, file, DateTimeOffset.UtcNow, payload.CapturedAt + CapturePolicy.Retention));
                    if (arrivals.Count > 16) arrivals.RemoveRange(0, arrivals.Count - 16);
                }
            }
            return true;
        }
        finally { delivery.Release(); }
    }
    internal bool QueueText(Func<Task> action, CancellationToken token)
    {
        if (disposed || token.IsCancellationRequested) return false;
        if (Interlocked.Increment(ref textQueued) > 16) { Interlocked.Decrement(ref textQueued); return false; }
        _ = Task.Run(async () => { try { token.ThrowIfCancellationRequested(); await action().ConfigureAwait(false); } catch (OperationCanceledException) { } finally { Interlocked.Decrement(ref textQueued); } });
        return true;
    }
    internal void Forget() { lock (arrivalsGate) arrivals.Clear(); }
    public void Dispose() { disposed = true; Forget(); /* In-flight finally blocks still own the semaphores. */ }
}
