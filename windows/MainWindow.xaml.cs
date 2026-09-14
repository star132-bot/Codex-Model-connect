using System.Windows;
using System.Windows.Controls;

namespace CodexModelManager.Windows;

public partial class MainWindow : Window
{
    private readonly ManagerService manager = new();
    private ProviderRecord? editing;
    private bool loading;

    public MainWindow()
    {
        InitializeComponent();
        ProtocolBox.SelectedIndex = 0;
        Reload();
    }

    private void Reload()
    {
        loading = true;
        ProviderList.Items.Clear();
        foreach (var provider in manager.State.Providers)
        {
            var item = new ListBoxItem {
                Tag = provider.Id,
                Content = $"{(provider.Enabled ? "●" : "○")}  {provider.Name}\n     {provider.ModelId}",
                Padding = new Thickness(10), Margin = new Thickness(0, 2, 0, 2)
            };
            ProviderList.Items.Add(item);
        }
        ModeBox.SelectedIndex = manager.State.ConfigurationMode == "desktopMenu" ? 1 : 0;
        ActiveTitle.Text = manager.ActiveTitle;
        loading = false;
    }

    private void AddProvider(object sender, RoutedEventArgs e) => ClearEditor();

    private void OpenAntigravity(object sender, RoutedEventArgs e)
    {
        new AntigravityWindow(manager) { Owner = this }.ShowDialog();
        Reload();
    }

    private void ClearEditor()
    {
        editing = null;
        PanelTitle.Text = "添加厂商";
        NameBox.Text = UrlBox.Text = KeyBox.Password = "";
        ModelBox.ItemsSource = null; ModelBox.Text = "";
        ProtocolBox.SelectedIndex = 0; EnabledBox.IsChecked = true; DefaultBox.IsChecked = true;
        DeleteButton.Visibility = Visibility.Collapsed; KeyState.Text = "";
    }

    private void ProviderSelected(object sender, SelectionChangedEventArgs e)
    {
        if (ProviderList.SelectedItem is not ListBoxItem item) return;
        editing = manager.State.Providers.FirstOrDefault(p => p.Id == (string)item.Tag);
        if (editing is null) return;
        PanelTitle.Text = editing.Name;
        NameBox.Text = editing.Name; UrlBox.Text = editing.BaseUrl; KeyBox.Password = "";
        ProtocolBox.SelectedIndex = editing.Protocol switch { "chatCompletions" => 1, "gemini" => 2, _ => 0 };
        ModelBox.ItemsSource = new[] { editing.ModelId }; ModelBox.Text = editing.ModelId;
        EnabledBox.IsChecked = editing.Enabled;
        DefaultBox.IsChecked = manager.State.ActiveProviderId == editing.Id;
        DeleteButton.Visibility = Visibility.Visible;
        KeyState.Text = CredentialStore.Exists(editing.Id) ? "密钥已保存（本次会话已解锁）" : "请重新输入密钥";
    }

    private string Protocol => (ProtocolBox.SelectedItem as ComboBoxItem)?.Tag?.ToString() ?? "responses";

    private async void FetchModels(object sender, RoutedEventArgs e)
    {
        await Busy(async () => {
            var key = ResolveKey();
            var models = await ProviderClient.FetchModelsAsync(UrlBox.Text, key, Protocol);
            ModelBox.ItemsSource = models;
            ModelBox.SelectedIndex = 0;
            StatusText.Text = $"已读取 {models.Count} 个模型；请选择一个";
        });
    }

    private async void SaveProvider(object sender, RoutedEventArgs e)
    {
        await Busy(async () => {
            var name = NameBox.Text.Trim(); var url = UrlBox.Text.Trim().TrimEnd('/'); var model = ModelBox.Text.Trim();
            if (name.Length == 0 || url.Length == 0 || model.Length == 0) throw new InvalidOperationException("请填写厂商、URL 和模型");
            var key = ResolveKey();
            await ProviderClient.TestAsync(url, key, model, Protocol);
            var record = editing ?? new ProviderRecord { Id = "cmm_" + Guid.NewGuid().ToString("N") };
            record.Name = name; record.BaseUrl = url; record.Protocol = Protocol; record.ModelId = model;
            record.DisplayName = model; record.Enabled = EnabledBox.IsChecked == true; record.VerifiedAt = DateTimeOffset.UtcNow;
            manager.Upsert(record, key, DefaultBox.IsChecked == true);
            editing = record; Reload();
            StatusText.Text = Protocol == "responses"
                ? "API 已验证并导入 Codex；完全重启 Desktop 后新建任务使用"
                : "API 已验证并保存；该协议不能作为 Codex 主模型";
        });
    }

    private string ResolveKey()
    {
        var entered = KeyBox.Password.Trim();
        if (entered.Length > 0) return entered;
        if (editing is not null && CredentialStore.Read(editing.Id) is { Length: > 0 } saved) return saved;
        throw new InvalidOperationException("请输入 API Key");
    }

    private void DeleteProvider(object sender, RoutedEventArgs e)
    {
        if (editing is null) return;
        if (MessageBox.Show($"删除 {editing.Name}？", "Codex 模型管理器", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes) return;
        manager.Delete(editing); ClearEditor(); Reload(); StatusText.Text = "已删除厂商";
    }

    private void UseGpt(object sender, RoutedEventArgs e)
    {
        try { manager.UseGpt(); Reload(); StatusText.Text = "已将本地 GPT 设为新任务默认"; }
        catch (Exception ex) { ShowError(ex); }
    }

    private void ModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (loading || ModeBox.SelectedItem is not ComboBoxItem item) return;
        try { manager.SetMode(item.Tag?.ToString() ?? "isolatedProfile"); Reload(); StatusText.Text = "配置模式已更新"; }
        catch (Exception ex) { ShowError(ex); }
    }

    private void ProtocolChanged(object sender, SelectionChangedEventArgs e)
    {
        if (SaveButton is not null) SaveButton.Content = Protocol == "responses" ? "测试、保存并导入 Codex" : "测试并保存";
    }

    private async Task Busy(Func<Task> work)
    {
        IsEnabled = false;
        try { await work(); }
        catch (Exception ex) { ShowError(ex); }
        finally { IsEnabled = true; }
    }

    private void ShowError(Exception ex)
    {
        StatusText.Text = ex.Message;
        MessageBox.Show(ex.Message, "Codex 模型管理器", MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
