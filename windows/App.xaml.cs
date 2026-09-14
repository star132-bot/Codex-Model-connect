using System.Windows;

namespace CodexModelManager.Windows;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        if (e.Args.Length >= 1 && e.Args[0] == "--print-key")
        {
            Shutdown(CredentialStore.Print(e.Args.ElementAtOrDefault(1)) ? 0 : 1);
            return;
        }
        if (e.Args.Length == 1 && e.Args[0] == "--router")
        {
            Shutdown(LocalRouter.RunAsync().GetAwaiter().GetResult());
            return;
        }
        base.OnStartup(e);
        new MainWindow().Show();
    }
}
