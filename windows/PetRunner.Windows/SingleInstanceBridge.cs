using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;

namespace PetRunner.Windows;

internal sealed class SingleInstanceBridge : IDisposable
{
    private readonly Mutex mutex;
    private readonly string pipeName;
    private readonly CancellationTokenSource cancellation = new();
    private readonly Action activate;
    private readonly Task listener;

    private SingleInstanceBridge(Mutex mutex, string pipeName, Action activate)
    {
        this.mutex = mutex;
        this.pipeName = pipeName;
        this.activate = activate;
        listener = Task.Run(Listen);
    }

    public static SingleInstanceBridge? TryBecomePrimary(Action activate, bool activateExisting)
    {
        var suffix = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserName))).ToLowerInvariant()[..16];
        var pipeName = $"PetRunner-{suffix}";
        var mutex = new Mutex(initiallyOwned: true, $"Local\\PetRunner-{suffix}", out var createdNew);
        if (createdNew) return new SingleInstanceBridge(mutex, pipeName, activate);
        mutex.Dispose();
        if (activateExisting) NotifyExisting(pipeName);
        return null;
    }

    private static void NotifyExisting(string pipeName)
    {
        for (var attempt = 0; attempt < 4; attempt++)
        {
            try
            {
                using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out);
                client.Connect(250);
                using var writer = new StreamWriter(client, Encoding.UTF8, leaveOpen: false) { AutoFlush = true };
                writer.WriteLine("open-dashboard");
                return;
            }
            catch (TimeoutException) { Thread.Sleep(50); }
            catch (IOException) { Thread.Sleep(50); }
        }
    }

    private async Task Listen()
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await using var server = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(cancellation.Token);
                using var reader = new StreamReader(server, Encoding.UTF8, leaveOpen: true);
                if (await reader.ReadLineAsync(cancellation.Token) == "open-dashboard") activate();
            }
            catch (OperationCanceledException) { return; }
            catch (IOException) when (!cancellation.IsCancellationRequested) { }
        }
    }

    public void Dispose()
    {
        cancellation.Cancel();
        try { listener.Wait(TimeSpan.FromSeconds(1)); } catch { }
        cancellation.Dispose();
        try { mutex.ReleaseMutex(); } catch (ApplicationException) { }
        mutex.Dispose();
    }
}
