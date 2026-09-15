using Microsoft.Win32;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace CodexModelManager.Windows;

public sealed class ConfigurationProfilesWindow : Window
{
    private readonly ManagerService manager;
    private readonly StackPanel profiles = new();
    private readonly TextBlock status = new() { Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap };
    private readonly TextBox snapshotName = new() { Text = "我的当前配置" };
    private readonly TextBox relayName = new();
    private readonly TextBox relayUrl = new();
    private readonly PasswordBox relayKey = new();
    private readonly TextBox relayModel = new() { Text = "gpt-5.5" };
    private readonly TextBox reviewModel = new() { Text = "gpt-5.5" };
    private readonly TextBox catalogPath = new() { Text = "~/.codex/codex-models.json" };

    public ConfigurationProfilesWindow(ManagerService manager)
    {
        this.manager = manager; Title = "Codex 配置方案"; Width = 920; Height = 650; MinWidth = 780; MinHeight = 540; WindowStartupLocation = WindowStartupLocation.CenterOwner; Background = Brushes.White;
        var root = new Grid { Margin = new Thickness(22) }; root.ColumnDefinitions.Add(new ColumnDefinition()); root.ColumnDefinitions.Add(new ColumnDefinition());
        var left = new StackPanel { Margin = new Thickness(0, 0, 18, 0) }; Grid.SetColumn(left, 0);
        left.Children.Add(new TextBlock { Text = "Codex 配置方案", FontSize = 25, FontWeight = FontWeights.SemiBold });
        left.Children.Add(new TextBlock { Text = "成对保存 config.toml 与 auth.json；登录令牌和 Key 保存在 Windows Credential Manager。", Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 14) });
        left.Children.Add(Label("当前配置名称")); left.Children.Add(snapshotName); left.Children.Add(Button("保存当前配置", (_, _) => Run(() => manager.CaptureCurrentConfiguration(snapshotName.Text))));
        left.Children.Add(Button("导入配置文件夹", (_, _) => Import())); left.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 10) });
        left.Children.Add(new TextBlock { Text = "已保存方案", FontWeight = FontWeights.SemiBold });
        left.Children.Add(new ScrollViewer { Content = profiles, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Height = 370 });

        var right = new StackPanel { Margin = new Thickness(18, 0, 0, 0) }; Grid.SetColumn(right, 1);
        right.Children.Add(new TextBlock { Text = "新建 API 中转配置", FontSize = 20, FontWeight = FontWeights.SemiBold });
        AddField(right, "方案名称", relayName); AddField(right, "API URL", relayUrl); AddField(right, "API Key", relayKey); AddField(right, "主模型", relayModel); AddField(right, "Review 模型", reviewModel); AddField(right, "模型目录路径（可选）", catalogPath);
        right.Children.Add(Button("保存中转配置", (_, _) => Run(() => { manager.CreateRelayConfiguration(relayName.Text, relayUrl.Text, relayKey.Password, relayModel.Text, reviewModel.Text, catalogPath.Text); relayKey.Password = ""; })));
        right.Children.Add(new TextBlock { Text = "切换会先备份当前配置，再同时替换两份文件。切换后需要完全退出并重新打开 Codex。", Foreground = Brushes.DimGray, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 14, 0, 8) }); right.Children.Add(status);
        root.Children.Add(left); root.Children.Add(right); Content = root; Reload();
    }

    private static TextBlock Label(string text) => new() { Text = text, Margin = new Thickness(0, 8, 0, 3) };
    private static void AddField(Panel panel, string name, Control control) { panel.Children.Add(Label(name)); control.Padding = new Thickness(7, 5, 7, 5); panel.Children.Add(control); }
    private static Button Button(string text, RoutedEventHandler action) { var button = new Button { Content = text, Margin = new Thickness(0, 8, 6, 0), Padding = new Thickness(12, 7, 12, 7), HorizontalAlignment = HorizontalAlignment.Left }; button.Click += action; return button; }

    private void Reload()
    {
        profiles.Children.Clear();
        foreach (var profile in manager.State.ConfigurationProfiles) {
            var card = new StackPanel { Margin = new Thickness(0, 5, 0, 8) };
            card.Children.Add(new TextBlock { Text = profile.Name + (manager.State.ActiveConfigurationProfileId == profile.Id ? "  · 当前" : ""), FontWeight = FontWeights.SemiBold });
            card.Children.Add(new TextBlock { Text = $"{profile.Kind} · {profile.Model}\n{profile.BaseUrl}", Foreground = Brushes.DimGray });
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            actions.Children.Add(Button("一键切换", (_, _) => Run(() => manager.SwitchConfiguration(profile)))); actions.Children.Add(Button("删除", (_, _) => Run(() => manager.DeleteConfiguration(profile)))); card.Children.Add(actions); profiles.Children.Add(card);
        }
    }

    private void Import()
    {
        var dialog = new OpenFileDialog { Title = "选择要导入的 config.toml", Filter = "config.toml|config.toml|TOML|*.toml" };
        if (dialog.ShowDialog(this) == true) Run(() => manager.ImportConfiguration(new DirectoryInfo(Path.GetDirectoryName(dialog.FileName)!).Name + " 配置", Path.GetDirectoryName(dialog.FileName)!));
    }

    private void Run(Action action)
    {
        try { action(); status.Text = "操作完成。切换配置后请完全重启 Codex。"; Reload(); }
        catch (Exception ex) { status.Text = ex.Message; MessageBox.Show(ex.Message, "Codex 配置方案", MessageBoxButton.OK, MessageBoxImage.Error); }
    }
}
