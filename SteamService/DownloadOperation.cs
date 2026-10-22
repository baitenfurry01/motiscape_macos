using System.Runtime.CompilerServices;

[assembly: InternalsVisibleTo("SteamServiceRegression")]

namespace MotiscapeSteamService;

/// One attempt owns its cancellation lifetime. A pause acknowledgement is only
/// emitted after all downloader workers have unwound and released their files.
internal sealed class DownloadOperation : IDisposable
{
    private readonly CancellationTokenSource cancellation = new();
    private readonly object gate = new();
    private bool disposed;
    private string? stopReason;
    public string Destination { get; }
    public CancellationToken Token { get; }
    public Task Task { get; set; } = Task.CompletedTask;

    public DownloadOperation(string destination)
    {
        Destination = destination;
        Token = cancellation.Token;
    }

    public void Pause() => Stop("paused");
    public void Cancel() => Stop("cancelled");
    private void Stop(string reason)
    {
        lock (gate)
        {
            if (disposed) return;
            // An explicit cancel wins over an earlier/later pause request.
            if (stopReason != "cancelled") stopReason = reason;
            try { cancellation.Cancel(); } catch (AggregateException) { }
        }
    }

    public async Task RunAsync(string taskId,
        Func<CancellationToken, Task<WorkshopDownloader.DownloadResult>> action,
        ProtocolWriter writer, Action release)
    {
        var state = "failed";
        long total = 0;
        string? path = null, message = null, code = null;
        try
        {
            var result = await action(Token).ConfigureAwait(false);
            // The atomic install may have completed just before a pause arrived.
            state = "completed"; total = result.TotalBytes; path = result.OutputPath;
        }
        catch (Exception) when (Token.IsCancellationRequested)
        {
            lock (gate) state = stopReason ?? "cancelled";
            code = state == "paused" ? "DOWNLOAD_PAUSED" : "DOWNLOAD_CANCELLED";
            message = state == "paused" ? "Download paused; verified chunks are retained." : "Download was cancelled.";
        }
        catch (Exception error)
        {
            while (error.InnerException != null && error is AggregateException or IOException) error = error.InnerException;
            message = error.Message;
            code = error is ServiceException failure ? failure.Code :
                error is OperationCanceledException ? "DOWNLOAD_INTERRUPTED" : "UNEXPECTED_ERROR";
        }
        finally
        {
            Dispose();
            release();
        }
        // Release attempt/destination slots before the client can request resume.
        writer.DownloadState(taskId, state, total, total, outputPath: path, message: message, errorCode: code);
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            cancellation.Dispose();
        }
    }
}
