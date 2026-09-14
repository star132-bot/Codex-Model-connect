using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexModelManager.Windows;

public sealed class AntigravityWindow : Window
{
    private readonly ManagerService manager;
    private readonly TextBlock status = new() { Text = "尚未检测", Foreground = Brushes.DimGray, Margin = new Thickness(0, 0, 0, 10) };
    private readonly StackPanel models = new();
    private readonly TextBox output = new() { IsReadOnly = true, AcceptsReturn = true, Height = 110, TextWrapping = TextWrapping.Wrap, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private string? executable;

    public AntigravityWindow(ManagerService manager)
    {
        this.manager = manager; Title = "Antigravity 账号"; Width = 760; Height = 620; WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = Brushes.White;
        var root = new StackPanel { Margin = new Thickness(24) };
        root.Children.Add(new TextBlock { Text = "Antigravity 账号", FontSize = 25, FontWeight = FontWeights.SemiBold }); root.Children.Add(status);
        var actions = new WrapPanel();
        actions.Children.Add(Button("一键安装", async (_, _) => await Install())); actions.Children.Add(Button("打开登录", (_, _) => Login()));
        actions.Children.Add(Button("刷新模型", async (_, _) => await Detect())); actions.Children.Add(Button("查询额度", async (_, _) => await Usage()));
        root.Children.Add(actions); root.Children.Add(new TextBlock { Text = "可用模型", FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 15, 0, 8) });
        root.Children.Add(new ScrollViewer { Content = models, Height = 245, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        root.Children.Add(Button("测试并导入 Codex", async (_, _) => await Import())); root.Children.Add(output); Content = root;
        Loaded += async (_, _) => await Detect();
    }

    private static Button Button(string text, RoutedEventHandler action) { var button = new Button { Content = text, Margin = new Thickness(3), Padding = new Thickness(14, 7, 14, 7) }; button.Click += action; return button; }
    private IEnumerable<CheckBox> Checks => models.Children.OfType<CheckBox>();

    private async Task Detect()
    {
        await Busy(async () => {
            executable = AgyService.Find(); models.Children.Clear();
            if (executable is null) { status.Text = "未安装 agy CLI"; return; }
            var result = await AgyService.RunAsync(["models"]); var found = AgyService.ParseModels(result.Output); status.Text = found.Count > 0 ? $"已安装并读取 {found.Count} 个模型" : "已安装；请先完成 Google 登录";
            var imported = manager.State.Providers.Where(p => p.IsAntigravity).Select(p => p.ModelId).ToHashSet();
            foreach (var model in found) models.Children.Add(new CheckBox { Content = model + (imported.Contains(model) ? "  · 已导入" : ""), Tag = model, IsChecked = imported.Contains(model), Margin = new Thickness(4) });
        });
    }

    private async Task Install()
    {
        await Busy(async () => { var start = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command \"irm https://antigravity.google/cli/install.ps1 | iex\"") { UseShellExecute = true }; using var process = Process.Start(start)!; await process.WaitForExitAsync(); await Detect(); });
    }
    private void Login()
    {
        executable = AgyService.Find(); if (executable is null) { MessageBox.Show("请先安装 agy CLI"); return; }
        Process.Start(new ProcessStartInfo("powershell.exe", $"-NoExit -Command \"& '{executable.Replace("'", "''")}'\"") { UseShellExecute = true });
    }
    private async Task Usage() { await Busy(async () => { var result = await AgyService.RunAsync(["-p", "/usage", "--output-format", "text"]); output.Text = result.Output; }); }
    private async Task Import()
    {
        await Busy(async () => {
            var selected = Checks.Where(c => c.IsChecked == true).Select(c => (string)c.Tag).ToList(); if (selected.Count == 0) throw new InvalidOperationException("请至少选择一个模型");
            var passed = new List<string>(); var report = new StringBuilder();
            foreach (var model in selected) { var result = await AgyService.RunAsync(["-p", "Reply with OK only.", "--model", model, "--output-format", "json", "--print-timeout", "30s"]); report.AppendLine($"{model}: {(result.ExitCode == 0 ? "通过" : "失败")}"); if (result.ExitCode == 0) passed.Add(model); }
            if (passed.Count == 0) throw new InvalidOperationException("选中模型均未通过测试"); manager.ImportAntigravity(passed); output.Text = report + $"\n已导入 {passed.Count} 个模型；完全重启 Codex Desktop 后新建任务使用。";
        });
    }
    private async Task Busy(Func<Task> work) { IsEnabled = false; try { await work(); } catch (Exception ex) { output.Text = ex.Message; MessageBox.Show(ex.Message, "Antigravity", MessageBoxButton.OK, MessageBoxImage.Error); } finally { IsEnabled = true; } }
}

public static class AgyService
{
    public sealed record Result(int ExitCode, string Output);
    public static string? Find()
    {
        var direct = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "agy", "bin", "agy.exe"); if (File.Exists(direct)) return direct;
        return ManagerService.FindExecutable("agy.exe") ?? ManagerService.FindExecutable("agy.cmd");
    }
    public static async Task<Result> RunAsync(IReadOnlyList<string> arguments)
    {
        var executable = Find() ?? throw new InvalidOperationException("agy CLI 未安装"); var start = new ProcessStartInfo(executable) { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
        foreach (var argument in arguments) start.ArgumentList.Add(argument); using var process = Process.Start(start)!; var stdout = process.StandardOutput.ReadToEndAsync(); var stderr = process.StandardError.ReadToEndAsync(); await process.WaitForExitAsync(); return new(process.ExitCode, (await stdout) + (await stderr));
    }
    public static List<string> ParseModels(string output) => Regex.Matches(output, @"\b(?:gemini|claude|gpt-oss)-[a-zA-Z0-9._-]+\b").Select(m => m.Value.TrimEnd('.', ',', ')')).Distinct().OrderBy(x => x).ToList();
}
