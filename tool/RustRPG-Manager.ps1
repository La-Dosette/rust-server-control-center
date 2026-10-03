[CmdletBinding()]
param(
    [string]$CapturePath,
    [switch]$ExitAfterCapture,
    # Borne = dernier index de MainTabs. 11 = Mods & Modes, 12 = assistant amis,
    # 13 = Mes serveurs, 14 = Centre des operations, 15 = assistant serveur. A elargir a chaque nouvel onglet, sinon la capture
    # echoue avec un code 1 peu explicite.
    [ValidateRange(0,23)][int]$CaptureTab = 0,
    [ValidateSet('simple','advanced')][string]$CaptureUiMode,
    [ValidateSet('fr-FR','en-US')][string]$CaptureLanguage,
    [ValidateRange(1,6)][int]$CaptureWizardStep = 1,
    [string]$CaptureWizardServerName = 'Serveur amis',
    [ValidateRange(1025,65535)][int]$CaptureWizardServerPort = 28215,
    [switch]$CaptureScheduleDemo,
    [switch]$CaptureDiagnosticDemo,
    [switch]$CaptureOnboardingDemo,
    [string]$MaintenanceInteractionQaPath,
    [string]$V12InteractionQaPath,
    [string]$V8InteractionQaPath,
    [switch]$ForceVanillaUi
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, System.Net.Http
if (-not ('RustControlCenter.NativeWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RustControlCenter {
    public static class NativeWindow {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    }
}
'@
}
. (Join-Path $PSScriptRoot 'RustRPG-Common.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Operations.ps1')
. (Join-Path $PSScriptRoot 'RustRPG-Services.ps1')

$ServerRoot = Split-Path $PSScriptRoot -Parent
$MutexCreated = $false
$MutexName = if ($CapturePath) { 'Local\RustRPGControlCenterV2Capture' } else { 'Local\RustRPGControlCenterV2' }
$Mutex = [Threading.Mutex]::new($true, $MutexName, [ref]$MutexCreated)
if (-not $MutexCreated) {
    [Windows.MessageBox]::Show('Rust Server Control Center est deja ouvert.', 'Rust Server Control Center') | Out-Null
    exit 0
}

$XamlPath = Join-Path $PSScriptRoot 'RustRPG-Manager.xaml'
$XamlText = [IO.File]::ReadAllText($XamlPath, [Text.Encoding]::UTF8)
[xml]$Xaml = $XamlText
$Reader = New-Object Xml.XmlNodeReader $Xaml
$Window = [Windows.Markup.XamlReader]::Load($Reader)
$IconPath = Join-Path $PSScriptRoot 'RustServerControlCenter-v4.ico'
if (-not (Test-Path -LiteralPath $IconPath)) {
    $IconPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter-v3.ico'
}
if (-not (Test-Path -LiteralPath $IconPath)) {
    $IconPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter-v2.ico'
}
if (-not (Test-Path -LiteralPath $IconPath)) {
    $IconPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter.ico'
}
if (Test-Path -LiteralPath $IconPath) {
    $Window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$IconPath)
}

# ----- Identite dans la barre des taches ---------------------------------------
# Pour Windows, l'application est powershell.exe : la barre des taches regroupait
# la fenetre sous l'icone de PowerShell. Un identifiant d'application propre lui
# fait utiliser l'icone de la fenetre, et les proprietes de relance font qu'un
# « Epingler a la barre des taches » relance le Control Center, pas un
# PowerShell nu.
if (-not ('RustControlCenter.AppIdentity' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RustControlCenter {
    public static class AppIdentity {
        [DllImport("shell32.dll")]
        private static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);

        [DllImport("shell32.dll")]
        private static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, [Out, MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);

        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant value);

        [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPropertyStore {
            [PreserveSig] int GetCount(out uint count);
            [PreserveSig] int GetAt(uint index, out PropertyKey key);
            [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
            [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
            [PreserveSig] int Commit();
        }

        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        private struct PropertyKey { public Guid FormatId; public uint PropertyId; }

        // PROPVARIANT fait 24 octets en 64 bits : on reserve toute la taille.
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        private struct PropVariant { [FieldOffset(0)] public ushort VarType; [FieldOffset(8)] public IntPtr Pointer; }

        private static readonly Guid StoreId = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
        private static readonly Guid AppUserModel = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");

        public static int SetProcessAppId(string appId) { return SetCurrentProcessExplicitAppUserModelID(appId); }

        public static string SetWindowIdentity(IntPtr hwnd, string appId, string command, string icon, string name) {
            Guid iid = StoreId;
            IPropertyStore store;
            int hr = SHGetPropertyStoreForWindow(hwnd, ref iid, out store);
            if (hr != 0 || store == null) return "echec " + hr;
            try {
                // Commande, icone et nom de relance AVANT l'identifiant : Windows
                // relit les proprietes de relance quand l'identifiant change.
                Write(store, 2, command);
                Write(store, 3, icon);
                Write(store, 4, name);
                Write(store, 5, appId);
                store.Commit();
                return "ok";
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        public static string ReadWindowAppId(IntPtr hwnd) {
            Guid iid = StoreId;
            IPropertyStore store;
            if (SHGetPropertyStoreForWindow(hwnd, ref iid, out store) != 0 || store == null) return null;
            try {
                PropertyKey key = new PropertyKey { FormatId = AppUserModel, PropertyId = 5 };
                PropVariant value;
                if (store.GetValue(ref key, out value) != 0) return null;
                string text = value.VarType == 31 ? Marshal.PtrToStringUni(value.Pointer) : null;
                PropVariantClear(ref value);
                return text;
            }
            finally { Marshal.ReleaseComObject(store); }
        }

        private static void Write(IPropertyStore store, uint id, string text) {
            PropertyKey key = new PropertyKey { FormatId = AppUserModel, PropertyId = id };
            PropVariant value = new PropVariant { VarType = 31, Pointer = Marshal.StringToCoTaskMemUni(text) };
            try { store.SetValue(ref key, ref value); }
            finally { Marshal.FreeCoTaskMem(value.Pointer); }
        }
    }
}
'@
}
$script:AppUserModelId = 'RustServerControlCenter.App'
try { $null = [RustControlCenter.AppIdentity]::SetProcessAppId($script:AppUserModelId) } catch { }
$Window.Add_SourceInitialized({
    try {
        $Handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        $Launcher = Join-Path (Split-Path $PSScriptRoot -Parent) 'LANCER-RUST-RPG-APP.vbs'
        $Command = '"' + (Join-Path $env:SystemRoot 'System32\wscript.exe') + '" "' + $Launcher + '"'
        $null = [RustControlCenter.AppIdentity]::SetWindowIdentity($Handle, $script:AppUserModelId, $Command, $IconPath, 'Rust Server Control Center')
    }
    catch { }
})
$BrushConverter = New-Object Windows.Media.BrushConverter

$ControlNames = @(
    'HeaderLogoImage','HeaderTitleText','HeaderSubtitleText','HeaderInstanceCombo','HeaderStartButton','LanguageCombo','InterfaceModeButton','TopStatusBorder','TopStatusDot','TopStatusText','SidebarModeLabel','SimpleNavigation','Navigation','MainTabs','NavGroupServerHeader','NavGroupWorldHeader','NavGroupGameHeader','SubNavBar','SubNavPanel','ModesTabItem','SimpleHelpButton','AdvancedConnectionCard','SideConnectionTitleText','SideAddressText','SideAddressUpdatedText','SideBoxRuleText','SideReachText','LobbyReloadButton','LobbySaveButton','LobbyApplyButton','LobbyNoticeText','LobbyToolPanel','LobbyRowsBox','LobbyColsBox','LobbyResizeButton','LobbyPresetRoundButton','LobbyPresetSquareButton','LobbyClearButton','LobbyGrid','LobbyStatsText','LobbyWarningText','LobbyNameBox','LobbyAltitudeBox','LobbyGradeCombo','LobbyRailCheck','LobbyDayCheck','LobbyMiniGamesCheck','LobbyPortalPanel','LobbyGridModeButton','LobbyPreviewInfoText','LobbyPreviewResetButton','LobbyViewportHost','LobbyCamera','LobbyModelVisual','SideRefreshAddressButton','SideCopyButton',
    'GlobalOperationBar','GlobalOperationStatusDot','GlobalOperationTitleText','GlobalOperationStageText','GlobalOperationProgressBar','GlobalOperationPercentText','GlobalOperationOpenButton',
    'SimpleHomeScroll','AdvancedDashboardScroll','SimpleLocalActionButton','SimpleFriendsActionButton','SimpleModsActionButton','SimpleChangeServerButton','SimpleServerNameText','SimpleServerStateText','SimpleServerAddressText','SimpleEnvironmentText',
    'SimpleModsTitle','SimpleModsSubtitle','SimpleModsEnvBorder','SimpleModsEnvTitle','SimpleModsEnvText','SimpleModsEnvActionButton','SimpleModsDetectedCountText','SimpleModsActiveCountText','SimpleModsModeCountText','SimpleModsIssueCountText','SimpleModsSearchBox','SimpleModsCategoryCombo','SimpleModsStateCombo','SimpleModsImportButton','SimpleModsListLabel','SimpleModsList','SimpleModsEmptyText','SimpleModsRefreshButton','SimpleModsAdvancedButton',
    'SimpleFriendsHeadline','SimpleFriendsAddress','SimpleFriendsCopyButton','SimpleFriendsSteps','SimpleFriendsRefreshButton','SimpleFriendsAdvancedButton','FriendTestStageText','FriendTestPercentText','FriendTestProgressBar','FriendTestDetailText','FriendTestStartButton','FriendTestCancelButton','FriendTestOpenReportButton',
    'SimpleServersNoticeBorder','SimpleServersNoticeTitle','SimpleServersNoticeText','SimpleServersInstallButton','SimpleServersProgressPanel','SimpleServersProgressStage','SimpleServersProgressPercent','SimpleServersProgressBar','SimpleServersProgressDetail','SimpleServersListLabel','SimpleServersList','SimpleServersRefreshButton','SimpleServersCreateButton','SimpleServersAdvancedButton',
    'DashRestartButton','DashPlayersText','DashUptimeText','DashFpsText','DashEntitiesText',
    'DashConsoleOutput','DashConsoleBox','DashConsoleSendButton','DashConsoleClearButton','DashConsoleStatusButton','DashConsoleSaveButton','DashConsolePluginsButton',
    'DashPlayerGrid','DashPlayerSummaryText','DashPlayersManageButton',
    'RatesNoticeBorder','RatesNoticeText','RatesGlobal1Button','RatesGlobal2Button','RatesGlobal5Button','RatesGlobal10Button','RatesGlobalBox','RatesGlobalApplyButton',
    'RatesGatherCheck','RatesPickupCheck','RatesStackCheck','RatesStackBox','RatesCraftCheck','RatesCraftBox','RatesSmeltCheck','RatesSmeltBox','RatesSmeltHintText',
    'RatesDomainsApplyButton','RatesResourceList','RatesResourcesApplyButton','RatesResourcesResetButton','RatesRefreshButton',
    'OperationRefreshButton','OperationIdleBorder','OperationActiveBorder','OperationActiveTitleText','OperationActiveStatusBorder','OperationActiveStatusText','OperationActiveServerText','OperationActiveElapsedText','OperationActiveStageText','OperationActivePercentText','OperationActiveProgressBar','OperationActiveLogText','OperationCancelButton','OperationActiveLogButton','OperationFilterAllButton','OperationFilterRunningButton','OperationFilterSuccessButton','OperationFilterFailedButton','OperationHistoryGrid','OperationDetailEmptyText','OperationDetailContentPanel','OperationDetailTitleText','OperationDetailStatusText','OperationDetailServerText','OperationDetailDateText','OperationDetailDurationText','OperationDetailSummaryText','OperationDetailLogPathText','OperationRetryButton','OperationDiagnosticButton','OperationDetailLogButton',
    'WizardStep1Border','WizardStep2Border','WizardStep3Border','WizardStep4Border','WizardStep5Border','WizardStep1Number','WizardStep2Number','WizardStep3Number','WizardStep4Number','WizardStep5Number','WizardStep1DoneText','WizardStep2DoneText','WizardStep3DoneText','WizardStep4DoneText','WizardStep5DoneText',
    'WizardStep1Panel','WizardStep2Panel','WizardStep3Panel','WizardStep4Panel','WizardStep5Panel','WizardSuccessPanel','WizardFooterPanel','WizardPresetLocalBorder','WizardPresetFriendsBorder','WizardPresetCommunityBorder','WizardPresetLocalRadio','WizardPresetFriendsRadio','WizardPresetCommunityRadio','WizardNameBox','WizardIdentityBox','WizardEnabledCheck',
    'WizardAutoPortsCheck','WizardServerPortBox','WizardRconPortBox','WizardQueryPortBox','WizardAppPortBox','WizardPortsStatusText','WizardPublicInfoBorder','WizardPublicInfoText','WizardMapTypeCombo','WizardSeedBox','WizardRandomSeedButton','WizardWorldSizeCombo','WizardLevelUrlBox','WizardMapHelpText','WizardMaxPlayersBox','WizardMemoryBox','WizardSaveIntervalBox','WizardPveCheck','WizardCreativeCheck','WizardResourceText',
    'WizardSummaryProfileText','WizardSummaryMapText','WizardSummaryPlayersText','WizardSummaryPortsText','WizardSummaryResourcesText','WizardSummarySaveText','WizardSummaryNetworkBorder','WizardSelectAfterCheck','WizardSuccessText','WizardSuccessAddressText','WizardSuccessServersButton','WizardSuccessNetworkButton','WizardSuccessCloseButton','WizardBackButton','WizardCancelButton','WizardStepCounterText','WizardNextButton',
    'DashLocalButton','DashOnlineButton','DashUpdateButton','DashCopyButton','DashStateText','DashRustVersionText','DashMemoryText','DashPluginCountText','DashBackupCountText',
    'DashAddressText','DashJoinButton','DashStopButton','DashboardServerNameText','DashboardServerAddressText','DashboardEnvironmentText','DashboardEnvironmentNoticeBorder','DashboardEnvironmentTitleText','DashboardEnvironmentDescriptionText','DashboardExtensionsButton','DashboardActivityText','ServerLocalButton','ServerOnlineButton','ServerJoinButton',
    'ServerStopButton','StopAllInstancesButton','ServerRuntimeText','InstancesPageTitle','InstancesPageSubtitle','InstanceMultiWarningText','InstanceGrid',
    'NewInstanceButton','DuplicateInstanceButton','RemoveInstanceButton','InstanceEditorTitle','InstanceNameBox','InstanceIdentityBox',
    'InstanceGamePortBox','InstanceRconPortBox','InstanceQueryPortBox','InstanceAppPortBox','InstanceEnabledCheck','InstancePublicCheck','SaveInstanceButton',
    'AllowMultiInstanceCheck','InstanceResourceText','InstanceGamePortText','InstanceQueryPortText','InstanceRconPortText',
    'HostnameBox','DescriptionBox','MaxPlayersBox','SaveIntervalBox','PveCheck',
    'CreativeCheck','SaveServerSettingsButton','MapIdentityCombo','MapTypeCombo','MapSeedBox','RandomSeedButton',
    'MapSizeCombo','MapUrlBox','MapCurrentText','ApplyMapButton','GenerateMapButton','MapLibrarySummaryText','MapLibraryGrid','ImportRustEditMapButton','OpenMapLibraryButton','MapLibraryPublicUrlBox','SaveMapLibraryUrlButton','MapLibraryDetailText','ApplyImportedMapButton','ArenaSummaryText','ArenaProfileGrid','RefreshArenaProfilesButton','ArenaTemplateCombo','ArenaLocationCombo','GenerateArenaButton','CleanupArenaButton','WipeIdentityCombo',
    'ResetPluginDataCheck','CleanMapsCheck','CreateBackupButton','MapWipeButton','FullWipeButton','BackupGrid','RefreshBackupsButton','RestoreBackupButton',
    'MaintenanceWorkerStatusText','MaintenanceSummaryText','InstallMaintenanceWorkerButton','RemoveMaintenanceWorkerButton','ScheduleGrid','ScheduleEditorTitleText','ScheduleNameBox','ScheduleIdentityCombo','ScheduleActionCombo','ScheduleRecurrenceCombo','ScheduleTimeBox','ScheduleDayCombo','ScheduleIntervalBox','ScheduleRetentionBox','ScheduleEnabledCheck','ScheduleStopRestartCheck','ScheduleResetPluginDataCheck','ScheduleCleanMapsCheck','ScheduleNextRunText','NewScheduleButton','SaveScheduleButton','ToggleScheduleButton','RunScheduleButton','DeleteScheduleButton',
    'OpenBackupsButton','VerifyBackupButton','PluginSummaryText','PluginGrid','RefreshPluginsButton','EnablePluginButton','DisablePluginButton',
    'ReloadPluginButton','ImportPluginButton','PluginConfigButton','PluginSourceButton','ArchivePluginButton','InstallCarbonButton','InstallOxideButton','PluginGridBorder','PluginEmptyStateBorder',
    'PluginSdkTitleText','PluginSdkSummaryText','PluginSdkSettingsPanel','PluginSdkActionsPanel','PluginSdkStatusText','PluginSdkSaveButton','PluginSdkOpenConfigButton',
    'ModeEnvironmentText','ModePluginCountText','ModeCapabilityCountText','ModeCapabilityGrid','ModeInspectorTitleText','ModeInspectorPluginText','ModeInspectorConfigText','ModeInspectorStateText','ModeOpenConfigButton','ModeReloadPluginButton','ModeUnknownNoteText','ModeLivePanel','ModeLobbyPanel','ModeCompetitivePanel','ModeProgressionPanel','ModeGunGamePanel','ModeTowerDefensePanel','ModeDuelPanel','ModeTrainingPanel','ModeRewardsPanel','DuelRewardsGroup','ProgressionRewardsGroup','CompetitiveRewardsGroup',
    'ModeRefreshButton','ModeStateOutput','LobbyRebuildButton','ModePlayersButton','StartCtfButton','StartDomButton',
    'StartSndButton','StartExtractionButton','StartZombieButton','StartGunGameButton','StartTowerDefenseButton','StartTowerDefenseEndlessButton','StartTournamentButton',
    'StartTrainingButton','StartSparringButton','StopTrainingButton',
    'StopEventButton','StopZombieButton','StopGunGameButton','StopTowerDefenseButton','StopDuelButton','DuelXpRewardBox','DuelCoinRewardBox',
    'TournamentXpRewardBox','TournamentCoinRewardBox','ZombieKillXpRewardBox','ZombieKillCoinRewardBox',
    'WaveCoinRewardBox','ZombieVictoryXpRewardBox','ZombieVictoryCoinRewardBox','ModeXpRewardBox','ModeCoinRewardBox','SaveRewardsButton',
    'ConfigFileCombo','ReloadConfigButton','ValidateConfigButton','FormatConfigButton','ConfigModeTabs','VisualConfigSummaryText','VisualConfigGrid','ConfigEditor','SaveConfigButton','RefreshPlayersButton',
    'PlayerGrid','PlayerSummaryText','ModerationReasonBox','KickPlayerButton','BanPlayerButton','HealPlayerButton',
    'FreePlayerButton','MessagePlayerButton','BanGrid','RefreshBansButton','UnbanPlayerButton','ModerationGrid',
    'StatsSummaryText','RefreshStatsButton','ModeStatsGrid','LeaderboardGrid','PlayerStatsGrid','PlayerCardText',
    'PlayerNoteBox','SavePlayerNoteButton','NetworkSummaryText','NetworkLanIpText','NetworkPublicIpText','NetworkFriendText','NetworkProfileText',
    'NetworkDiagnosticGrid','RunNetworkDiagnosticButton','CopyNetworkReportButton','OpenUniversalNetworkGuideButton','RefreshNetworkAddressButton','OpenFirewallButton','OpenNetworkLiveboxButton','NetworkAddressTrackingText','NetworkDdnsEnabledCheck','NetworkDdnsProviderCombo','NetworkDdnsHostnameBox','NetworkDdnsIntervalBox','NetworkDdnsUsernameBox','NetworkDdnsSecretBox','NetworkDdnsSaveButton','NetworkDdnsTestButton','NetworkDdnsStatusText','NetworkAccessModeCombo','NetworkTunnelHostBox','NetworkTunnelPortBox','NetworkAccessSaveButton','NetworkOpenTunnelButton','NetworkCopyAlternativeCommandButton','NetworkAlternativeStatusText','NetworkTailscaleStateText','NetworkTailscaleIpText','NetworkTailscaleDeviceText','NetworkTailscalePeersText','NetworkTailscaleInstallButton','NetworkTailscaleLoginButton','NetworkTailscaleEnableButton','NetworkTailscaleRefreshButton','NetworkTailscaleInviteButton','NetworkTailscaleCopyGuideButton','NetworkTailscaleHelpText',
    'RconSaveButton','RconOutput','RconCommandBox','SendRconButton','BroadcastBox','BroadcastButton','LogFileCombo',
    'RefreshLogsButton','LogViewer','UpdateServerButton','OpenServerFolderButton','OpenLiveboxButton',
    'GlobalDiagnosticTitleText','GlobalDiagnosticSubtitleText','GlobalDiagnosticTotalText','GlobalDiagnosticOkText','GlobalDiagnosticWarningText','GlobalDiagnosticErrorText','GlobalDiagnosticSummaryText','GlobalDiagnosticGrid','RunGlobalDiagnosticButton','RepairSelectedDiagnosticButton','RepairGlobalDiagnosticButton','ExportGlobalDiagnosticButton','ReleaseUpdateStatusText','ReleaseRepositoryBox','ReleaseChannelCombo','SaveReleaseRepositoryButton','CheckControlCenterUpdateButton','InstallControlCenterUpdateButton','UpdateSignatureStatusText','UpdateBackupCombo','RefreshUpdateBackupsButton','RestoreControlCenterVersionButton',
    'OnboardingLogoImage','OnboardingTitleText','OnboardingSubtitleText','OnboardingAppStatusText','OnboardingHardwareStatusText','OnboardingVanillaRadio','OnboardingCarbonRadio','OnboardingOxideRadio','OnboardingEnvironmentStatusText','OnboardingServerStatusText','OnboardingProfilesStatusText','OnboardingNetworkStatusText','OnboardingNetworkButton','OnboardingAutomationStatusText','OnboardingInstallButton','OnboardingCreateServerButton','OnboardingBackgroundButton','OnboardingRepairButton','OnboardingDiagnosticButton','OnboardingLaterButton','OnboardingFinishButton',
    'InstanceIsolationCombo','InstanceIsolationCarbonCheck','ApplyInstanceIsolationButton','InstallIsolatedRuntimeButton','OpenInstanceRuntimeButton','InstanceIsolationStatusText','InstanceIsolationPathText','InstanceIsolationDetailText',
    'SupervisionRefreshButton','SupervisionInstallTaskButton','SupervisionRemoveTaskButton','SupervisionInstanceCombo','SupervisionTaskStatusText','SupervisionCpuText','SupervisionMemoryText','SupervisionUptimeText','SupervisionRconText','SupervisionChartCanvas','SupervisionCpuLine','SupervisionMemoryLine','SupervisionEnabledCheck','SupervisionAutoRestartCheck','SupervisionMaxRestartBox','SupervisionCooldownBox','SupervisionSavePolicyButton','SupervisionReadinessGrid','SupervisionEventGrid','SupervisionLastFailureText',
    'RemoteEnabledCheck','RemoteBindCombo','RemotePortBox','RemoteRconCheck','RemoteSaveButton','RemoteTokenBox','RemoteGenerateTokenButton','RemoteCopyTokenButton','RemoteUrlText','RemoteVpnStatusText','RemoteOpenButton','RemoteCopyVpnUrlButton','RemoteTestButton','RemoteServiceStatusText','RemoteStartServiceButton','RemoteStopServiceButton','RemoteInstanceGrid',
    'CatalogSyncButton','CatalogSourceNameBox','CatalogSourceUrlBox','CatalogAddSourceButton','CatalogSearchBox','CatalogCategoryCombo','CatalogSummaryText','AvailablePluginGrid','CatalogPluginTitleText','CatalogPluginDescriptionText','CatalogCompatibilityText','CatalogDependenciesText','CatalogSourceText','CatalogInstallButton','CatalogRemoveButton','CatalogHomepageButton','CatalogOpenSourcesButton',
    'HostHealthRefreshButton','HostHealthTaskManagerButton','HostHealthFirewallButton','HostHealthCpuText','HostHealthRamText','HostHealthDiskText','HostHealthCapacityText','HostHealthSummaryText','HostHealthGrid','HostHealthAdapterGrid','HostHealthRepairButton','HostHealthOpenSettingsButton','HostHealthCapacityDetailText',
    'OpenInstructionsButton','FooterVersionText','ActivityText'
)
$Ui = @{}
foreach ($Name in $ControlNames) { $Ui[$Name] = $Window.FindName($Name) }
# Un nom absent du XAML donnait un $null silencieux et une erreur cryptique au
# premier clic. On echoue ici, avec la liste exacte des controles manquants.
$MissingControls = @($ControlNames | Where-Object { $null -eq $Ui[$_] })
if ($MissingControls.Count -gt 0) {
    [Windows.MessageBox]::Show(
        "Controles absents de RustRPG-Manager.xaml :`n`n" + ($MissingControls -join "`n"),
        'Rust Server Control Center') | Out-Null
    exit 1
}
$script:UpdateOperation = $null
$script:UpdateProgressPulse = 0
$script:OperationFilter = 'All'
$script:OperationLastPersistAt = [datetime]::MinValue
$script:OperationNotifyIcon = $null
$script:AutomaticUpdateCheckProcess = $null
$script:AutomaticUpdateCheckResultPath = ''
$script:OnboardingRepairCode = ''
$script:OnboardingRepairDetail = ''
$script:WizardStep = 1
$script:WizardPreset = 'friends'
$script:WizardNavigationGuard = $false
$script:WizardCreatedInstance = $null
$script:SelectedScheduleId = ''
$script:MaintenanceWorkerLastLaunch = [datetime]::MinValue
$script:DdnsWorkerProcess = $null
$script:DdnsWorkerLastLaunch = [datetime]::MinValue
$script:MaintenanceEditorInitialized = $false
$script:MaintenanceEditorLoading = $false
$script:MaintenanceEditorDirty = $false
$LogoPath = Join-Path $PSScriptRoot 'RustServerControlCenter-Logo-v4.png'
if (-not (Test-Path -LiteralPath $LogoPath)) {
    $LogoPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter-Logo-v3.png'
}
if (-not (Test-Path -LiteralPath $LogoPath)) {
    $LogoPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter-Logo-v2.png'
}
if (-not (Test-Path -LiteralPath $LogoPath)) {
    $LogoPath = Join-Path $PSScriptRoot 'RustRPG-ControlCenter-Logo.png'
}
if (Test-Path -LiteralPath $LogoPath) {
    $LogoSource = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]$LogoPath)
    $Ui.HeaderLogoImage.Source = $LogoSource
    $Ui.OnboardingLogoImage.Source = $LogoSource
}

function Set-Activity([string]$Message) {
    $Ui.ActivityText.Text = $Message
    if ($Ui.DashboardActivityText) { $Ui.DashboardActivityText.Text = $Message }
}

function Show-Info([string]$Message, [string]$Title = 'Rust Server Control Center') {
    [Windows.MessageBox]::Show($Window, $Message, $Title, [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information) | Out-Null
}

function Get-OperationLogPath([string]$Type) {
    $Directory = Join-Path $ServerRoot 'logs\operations'
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $SafeType = if ($Type) { $Type.ToLowerInvariant() -replace '[^a-z0-9-]','-' } else { 'operation' }
    return Join-Path $Directory ("$SafeType-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.log')
}

function Write-TrackedOperationLog([string]$Path,[string]$Message) {
    if (-not $Path) { return }
    $Directory = Split-Path $Path -Parent
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $Line = ('[{0}] {1}{2}' -f (Get-Date -Format 'HH:mm:ss'),$Message,[Environment]::NewLine)
    [IO.File]::AppendAllText($Path,$Line,[Text.UTF8Encoding]::new($false))
}

function Get-OperationMetadataValue($Operation,[string]$Name,$Default = $null) {
    if ($Operation -and $Operation.metadata -and $Operation.metadata.PSObject.Properties.Name -contains $Name) { return $Operation.metadata.$Name }
    return $Default
}

function Get-OperationStatusDisplay([string]$Status) {
    switch ($Status) {
        'Running'     { return [pscustomobject]@{ Label='EN COURS'; Color='#72D79B'; Background='#233A32' } }
        'Succeeded'   { return [pscustomobject]@{ Label='RÉUSSIE'; Color='#9FD36F'; Background='#24422E' } }
        'Failed'      { return [pscustomobject]@{ Label='ÉCHEC'; Color='#E76A4C'; Background='#4B1E19' } }
        'Cancelled'   { return [pscustomobject]@{ Label='ANNULÉE'; Color='#FFD479'; Background='#3A3122' } }
        'Interrupted' { return [pscustomobject]@{ Label='INTERROMPUE'; Color='#FFD479'; Background='#3A3122' } }
        default       { return [pscustomobject]@{ Label=$Status.ToUpperInvariant(); Color='#8C8276'; Background='#232019' } }
    }
}

function Get-OperationDate([string]$IsoDate) {
    try { return [datetime]::Parse($IsoDate).ToLocalTime() } catch { return Get-Date }
}

function Format-OperationDuration([int]$Seconds) {
    $Span = [TimeSpan]::FromSeconds([math]::Max(0,$Seconds))
    if ($Span.TotalHours -ge 1) { return ('{0:00}:{1:00}:{2:00}' -f [int]$Span.TotalHours,$Span.Minutes,$Span.Seconds) }
    return ('{0:00}:{1:00}' -f $Span.Minutes,$Span.Seconds)
}

function Get-OperationElapsedSeconds($Operation) {
    if (-not $Operation) { return 0 }
    if ([int]$Operation.durationSeconds -gt 0 -or [string]$Operation.status -ne 'Running') { return [int]$Operation.durationSeconds }
    $Started = Get-OperationDate ([string]$Operation.startedUtc)
    return [math]::Max(0,[int]((Get-Date) - $Started).TotalSeconds)
}

function Get-OperationServerLabel($Operation) {
    if (-not $Operation -or -not [string]$Operation.serverId) { return 'GLOBAL' }
    try {
        $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
        $Instance = @($Catalog.instances | Where-Object { [string]$_.id -eq [string]$Operation.serverId -or [string]$_.identity -eq [string]$Operation.serverId }) | Select-Object -First 1
        if ($Instance) { return [string]$Instance.displayName }
    }
    catch { }
    return [string]$Operation.serverId
}

function Open-ControlCenterTab([int]$TabIndex) {
    if ($script:InterfaceMode -eq 'advanced' -and (Get-NavSection $TabIndex)) {
        Select-AdvancedNav -Tab $TabIndex
        return
    }
    $Ui.MainTabs.SelectedIndex = $TabIndex
    $List = if ($script:InterfaceMode -eq 'simple') { $Ui.SimpleNavigation } else { $Ui.Navigation }
    for ($Index = 0; $Index -lt $List.Items.Count; $Index++) {
        $Tag = $List.Items[$Index].Tag
        if ($null -ne $Tag -and [int]$Tag -eq $TabIndex) { $List.SelectedIndex = $Index; break }
    }
    if ($TabIndex -eq 14) { Refresh-OperationCenter }
}

function Set-OperationFilter([ValidateSet('All','Running','Succeeded','Failed')][string]$Filter) {
    $script:OperationFilter = $Filter
    $Buttons = @{
        All       = $Ui.OperationFilterAllButton
        Running   = $Ui.OperationFilterRunningButton
        Succeeded = $Ui.OperationFilterSuccessButton
        Failed    = $Ui.OperationFilterFailedButton
    }
    foreach ($Entry in $Buttons.GetEnumerator()) {
        $Selected = $Entry.Key -eq $Filter
        $Entry.Value.Background = $BrushConverter.ConvertFromString($(if ($Selected) { '#3A2118' } else { '#211F1C' }))
        $Entry.Value.BorderBrush = $BrushConverter.ConvertFromString($(if ($Selected) { '#D65332' } else { '#4A443D' }))
        $Entry.Value.Foreground = $BrushConverter.ConvertFromString($(if ($Selected) { '#FFF1E4' } else { '#EDE4D5' }))
    }
    Refresh-OperationCenter
}

function Update-OperationDetail {
    $Row = $Ui.OperationHistoryGrid.SelectedItem
    if (-not $Row -or -not $Row.Raw) {
        $Ui.OperationDetailEmptyText.Visibility = [Windows.Visibility]::Visible
        $Ui.OperationDetailContentPanel.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $Operation = $Row.Raw
    $Status = Get-OperationStatusDisplay ([string]$Operation.status)
    $Ui.OperationDetailEmptyText.Visibility = [Windows.Visibility]::Collapsed
    $Ui.OperationDetailContentPanel.Visibility = [Windows.Visibility]::Visible
    $Ui.OperationDetailTitleText.Text = ([string]$Operation.title).ToUpperInvariant()
    $Ui.OperationDetailStatusText.Text = [string]$Status.Label
    $Ui.OperationDetailStatusText.Foreground = $BrushConverter.ConvertFromString([string]$Status.Color)
    $Ui.OperationDetailServerText.Text = Get-OperationServerLabel $Operation
    $Ui.OperationDetailDateText.Text = (Get-OperationDate ([string]$Operation.startedUtc)).ToString('dd/MM/yyyy HH:mm:ss')
    $Ui.OperationDetailDurationText.Text = Format-OperationDuration (Get-OperationElapsedSeconds $Operation)
    $Ui.OperationDetailSummaryText.Text = if ([string]$Operation.detail) { [string]$Operation.detail } else { 'Aucun détail supplémentaire.' }
    $Ui.OperationDetailLogPathText.Text = if ([string]$Operation.logPath) { [string]$Operation.logPath } else { 'Aucun journal associé.' }
    $Ui.OperationRetryButton.IsEnabled = ([string]$Operation.retryAction -ne '' -and [string]$Operation.status -ne 'Running')
    $Ui.OperationDiagnosticButton.IsEnabled = $true
    $Ui.OperationDetailLogButton.IsEnabled = ([string]$Operation.logPath -ne '' -and (Test-Path -LiteralPath ([string]$Operation.logPath)))
}

function Get-DisplayedTrackedOperations {
    $Operations = @(Get-RustTrackedOperations -ServerRoot $ServerRoot)
    if (-not $CapturePath -or $CaptureTab -ne 14 -or $Operations.Count) { return $Operations }
    # Données uniquement visuelles pour la capture de référence. Rien n'est
    # écrit dans operation-center.json et l'application normale ne les voit pas.
    $Now = (Get-Date).ToUniversalTime()
    return @(
        [pscustomobject]@{ id='capture-active'; type='Update'; title='Mise à jour de Rust Dedicated'; serverId='GLOBAL'; status='Running'; progress=64.0; stage='RUST DEDICATED'; detail='SteamCMD télécharge et vérifie les fichiers Rust (68 %).'; startedUtc=$Now.AddMinutes(-12).ToString('o'); completedUtc=''; durationSeconds=0; logPath=''; errorLogPath=''; processId=0; retryAction='update'; canCancel=$true; notificationShown=$true; metadata=$null },
        [pscustomobject]@{ id='capture-success'; type='PluginImport'; title='Import du plugin DuelArena'; serverId='TEST'; status='Succeeded'; progress=100.0; stage='TERMINÉ'; detail='Le plugin a été copié et détecté dans le catalogue Carbon.'; startedUtc=$Now.AddHours(-1).ToString('o'); completedUtc=$Now.AddHours(-1).AddSeconds(16).ToString('o'); durationSeconds=16; logPath=''; errorLogPath=''; processId=0; retryAction='plugin-import'; canCancel=$false; notificationShown=$true; metadata=$null },
        [pscustomobject]@{ id='capture-failed'; type='MapGenerate'; title='Préparation de la carte TEST'; serverId='TEST'; status='Failed'; progress=82.0; stage='ÉCHEC'; detail='Le fichier de carte est verrouillé par un processus encore actif.'; startedUtc=$Now.AddHours(-2).ToString('o'); completedUtc=$Now.AddHours(-2).AddSeconds(42).ToString('o'); durationSeconds=42; logPath=''; errorLogPath=''; processId=0; retryAction='map-generate'; canCancel=$false; notificationShown=$true; metadata=([pscustomobject]@{identity='TEST'}) },
        [pscustomobject]@{ id='capture-wipe'; type='Wipe'; title='Wipe carte de TEST'; serverId='TEST'; status='Succeeded'; progress=100.0; stage='TERMINÉ'; detail='Sauvegarde créée et monde prêt pour la prochaine génération.'; startedUtc=$Now.AddDays(-1).ToString('o'); completedUtc=$Now.AddDays(-1).AddMinutes(2).ToString('o'); durationSeconds=120; logPath=''; errorLogPath=''; processId=0; retryAction='wipe'; canCancel=$false; notificationShown=$true; metadata=$null }
    )
}

function Refresh-OperationCenter {
    $SelectedId = if ($Ui.OperationHistoryGrid.SelectedItem) { [string]$Ui.OperationHistoryGrid.SelectedItem.Id } else { '' }
    try { $Operations = @(Get-DisplayedTrackedOperations) }
    catch {
        Set-Activity ('Historique indisponible : ' + $_.Exception.Message)
        return
    }
    $Filtered = switch ($script:OperationFilter) {
        'Running'   { @($Operations | Where-Object status -eq 'Running') }
        'Succeeded' { @($Operations | Where-Object status -eq 'Succeeded') }
        'Failed'    { @($Operations | Where-Object { [string]$_.status -in @('Failed','Interrupted') }) }
        default     { @($Operations) }
    }
    $Rows = @(foreach ($Operation in $Filtered) {
        $Status = Get-OperationStatusDisplay ([string]$Operation.status)
        [pscustomobject]@{
            Id           = [string]$Operation.id
            DateText     = (Get-OperationDate ([string]$Operation.startedUtc)).ToString('dd/MM HH:mm:ss')
            Title        = [string]$Operation.title
            ServerLabel  = Get-OperationServerLabel $Operation
            StatusLabel  = [string]$Status.Label
            DurationText = Format-OperationDuration (Get-OperationElapsedSeconds $Operation)
            Raw          = $Operation
        }
    })
    $Ui.OperationHistoryGrid.ItemsSource = $null
    $Ui.OperationHistoryGrid.ItemsSource = $Rows
    $Selected = @($Rows | Where-Object Id -eq $SelectedId) | Select-Object -First 1
    if ($Selected) { $Ui.OperationHistoryGrid.SelectedItem = $Selected }
    elseif ($Rows.Count -gt 0) { $Ui.OperationHistoryGrid.SelectedIndex = 0 }
    else { Update-OperationDetail }

    $Active = @($Operations | Where-Object status -eq 'Running' | Sort-Object startedUtc -Descending) | Select-Object -First 1
    if (-not $Active) {
        $Ui.GlobalOperationBar.Visibility = [Windows.Visibility]::Collapsed
        $Ui.OperationActiveBorder.Visibility = [Windows.Visibility]::Collapsed
        $Ui.OperationIdleBorder.Visibility = [Windows.Visibility]::Visible
        return
    }

    $Progress = [math]::Max([double]0,[math]::Min([double]100,[double]$Active.progress))
    $ServerLabel = Get-OperationServerLabel $Active
    $Ui.GlobalOperationBar.Visibility = [Windows.Visibility]::Visible
    $Ui.GlobalOperationTitleText.Text = ('TÂCHE GLOBALE : ' + [string]$Active.title).ToUpperInvariant()
    $Ui.GlobalOperationStageText.Text = [string]$Active.stage
    $Ui.GlobalOperationProgressBar.Value = $Progress
    $Ui.GlobalOperationPercentText.Text = ('{0} %' -f [math]::Round($Progress))

    $Ui.OperationIdleBorder.Visibility = [Windows.Visibility]::Collapsed
    $Ui.OperationActiveBorder.Visibility = [Windows.Visibility]::Visible
    $Ui.OperationActiveTitleText.Text = ([string]$Active.title).ToUpperInvariant()
    $Ui.OperationActiveServerText.Text = $ServerLabel
    $Ui.OperationActiveElapsedText.Text = Format-OperationDuration (Get-OperationElapsedSeconds $Active)
    $Ui.OperationActiveStageText.Text = [string]$Active.stage
    $Ui.OperationActiveProgressBar.Value = $Progress
    $Ui.OperationActivePercentText.Text = ('{0} %' -f [math]::Round($Progress))
    $Ui.OperationActiveLogText.Text = if ([string]$Active.detail) { [string]$Active.detail } else { 'Opération en cours...' }
    $Ui.OperationCancelButton.IsEnabled = [bool]$Active.canCancel
    $Ui.OperationActiveLogButton.IsEnabled = ([string]$Active.logPath -ne '' -and (Test-Path -LiteralPath ([string]$Active.logPath)))
}

function Get-TrackedOperationById([string]$Id) {
    if (-not $Id) { return $null }
    return @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object { [string]$_.id -eq $Id }) | Select-Object -First 1
}

function Get-SelectedTrackedOperation {
    $Row = $Ui.OperationHistoryGrid.SelectedItem
    if ($Row -and $Row.Raw) { return $Row.Raw }
    return $null
}

function Show-ControlCenterWindow {
    # Ramene notre propre fenetre au premier plan. Sans ca, l'icone de la zone
    # de notification est purement decorative : la fenetre existe, visible et
    # reactive, mais enfouie derriere les autres, et l'utilisateur conclut que
    # l'outil est bloque.
    try {
        $Handle = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
        if ($Handle -eq [IntPtr]::Zero) { return }
        if ($Window.WindowState -eq [Windows.WindowState]::Minimized) {
            $Window.WindowState = [Windows.WindowState]::Normal
        }
        if ($Window.Visibility -ne [Windows.Visibility]::Visible) { $Window.Visibility = [Windows.Visibility]::Visible }
        # 9 = SW_RESTORE : ressort la fenetre meme reduite dans la barre des taches.
        $null = [RustControlCenter.NativeWindow]::ShowWindowAsync($Handle, 9)
        $null = [RustControlCenter.NativeWindow]::SetForegroundWindow($Handle)
        $Window.Activate()
    }
    catch { Set-Activity ('Impossible de ramener la fenetre : ' + $_.Exception.Message) }
}

function Invoke-TrayAction([scriptblock]$Action) {
    # Execute l'action une fois le menu natif referme : une boite de dialogue
    # ouverte pendant que le menu termine sa boucle peut passer en arriere-plan.
    $Deferred = { Invoke-UiAction $Action }.GetNewClosure()
    $null = $Window.Dispatcher.BeginInvoke([Action]$Deferred, [Windows.Threading.DispatcherPriority]::Background)
}

function Stop-EverythingAndExit {
    Show-ControlCenterWindow
    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $Question = if ($Processes.Count) {
        "Sauvegarder puis arrêter $($Processes.Count) serveur(s), puis fermer le Control Center ?"
    } else {
        "Aucun serveur ne tourne. Fermer le Control Center ?"
    }
    if (-not (Confirm-Action $Question 'Tout arrêter')) { return }
    foreach ($Process in $Processes) {
        # L'etat voulu passe a "arrete" : sans cela, la supervision relancerait
        # le serveur en croyant a un plantage.
        if ([string]$Process.InstanceId) { $null = Set-RustDesiredState -ServerRoot $ServerRoot -InstanceId ([string]$Process.InstanceId) -State Stopped -Reason user }
        try { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Process.RconPort) -Command 'server.save' -TimeoutMs 8000 } catch { }
        try { $null = Send-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Process.RconPort) -Command 'quit' } catch { }
    }
    $Window.Close()
}

function Initialize-OperationNotifications {
    if ($CapturePath -or $script:OperationNotifyIcon) { return }
    try {
        $Notify = New-Object Windows.Forms.NotifyIcon
        if (Test-Path -LiteralPath $IconPath) { $Notify.Icon = [Drawing.Icon]::new($IconPath) }
        else { $Notify.Icon = [Drawing.SystemIcons]::Application }
        $Notify.Text = 'Rust Server Control Center'
        $Notify.Visible = $true
        $Notify.Add_BalloonTipClicked({ Show-ControlCenterWindow; Open-ControlCenterTab 14 })

        # Clic gauche et double-clic : le geste attendu, ouvrir l'outil.
        $Notify.Add_MouseClick({
            param($Sender, $EventArgs)
            if ($EventArgs.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-ControlCenterWindow }
        })
        $Notify.Add_DoubleClick({ Show-ControlCenterWindow })

        # Clic droit : menu NATIF (ContextMenu), pas ContextMenuStrip. Ce dernier
        # depend de la boucle de messages de Windows Forms, absente d'une app
        # WPF : il s'affichait, ne recevait aucun clic, restait bloque a l'ecran
        # et figeait l'application. Le menu natif gere lui-meme sa boucle.
        $Menu = New-Object Windows.Forms.ContextMenu
        $null = $Menu.MenuItems.Add('Ouvrir le Control Center', [EventHandler]{ Invoke-TrayAction { Show-ControlCenterWindow } })
        $null = $Menu.MenuItems.Add('-')
        # Les actions qui demandent confirmation remontent la fenetre d'abord :
        # sinon la boite de dialogue s'ouvre derriere les autres applications.
        $null = $Menu.MenuItems.Add('Démarrer le serveur', [EventHandler]{ Invoke-TrayAction { Show-ControlCenterWindow; Start-SelectedInstance } })
        $null = $Menu.MenuItems.Add('Arrêter le serveur', [EventHandler]{ Invoke-TrayAction { Show-ControlCenterWindow; Stop-SelectedInstance } })
        $null = $Menu.MenuItems.Add('-')
        $null = $Menu.MenuItems.Add('Centre des opérations', [EventHandler]{ Invoke-TrayAction { Show-ControlCenterWindow; Open-ControlCenterTab 14 } })
        $null = $Menu.MenuItems.Add('-')
        $null = $Menu.MenuItems.Add('Tout arrêter et quitter', [EventHandler]{ Invoke-TrayAction { Stop-EverythingAndExit } })
        $null = $Menu.MenuItems.Add('Quitter le Control Center', [EventHandler]{ Invoke-TrayAction { $Window.Close() } })
        $Notify.ContextMenu = $Menu

        $script:OperationNotifyIcon = $Notify
    }
    catch { Set-Activity ('Notifications indisponibles : ' + $_.Exception.Message) }
}

function Show-OperationNotification($Operation) {
    if ($CapturePath -or -not $Operation -or [bool]$Operation.notificationShown) { return }
    if ([string]$Operation.status -eq 'Running') { return }
    $LongTypes = @('Update','CarbonInstall','OxideInstall','ServerStart','MapGenerate','Wipe','Backup','PluginImport','IsolationInstall','PluginCatalogInstall','FriendTest')
    if ([int]$Operation.durationSeconds -lt 10 -and [string]$Operation.type -notin $LongTypes) {
        $null = Set-RustOperationNotificationShown -ServerRoot $ServerRoot -Id ([string]$Operation.id)
        return
    }
    Initialize-OperationNotifications
    if (-not $script:OperationNotifyIcon) { return }
    $Successful = [string]$Operation.status -eq 'Succeeded'
    $script:OperationNotifyIcon.BalloonTipTitle = if ($Successful) { 'Opération terminée' } else { 'Opération à vérifier' }
    $Detail = if ([string]$Operation.detail) { [string]$Operation.detail } else { [string]$Operation.title }
    if ($Detail.Length -gt 180) { $Detail = $Detail.Substring(0,177) + '...' }
    $script:OperationNotifyIcon.BalloonTipText = ([string]$Operation.title + "`r`n" + $Detail)
    $script:OperationNotifyIcon.BalloonTipIcon = if ($Successful) { [Windows.Forms.ToolTipIcon]::Info } else { [Windows.Forms.ToolTipIcon]::Warning }
    $script:OperationNotifyIcon.ShowBalloonTip(8000)
    $null = Set-RustOperationNotificationShown -ServerRoot $ServerRoot -Id ([string]$Operation.id)
}

function Show-PendingOperationNotifications {
    if ($CapturePath) { return }
    $Pending = @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object {
        [string]$_.status -ne 'Running' -and -not [bool]$_.notificationShown
    } | Sort-Object completedUtc | Select-Object -First 3)
    foreach ($Operation in $Pending) { Show-OperationNotification $Operation }
}

function Complete-TrackedOperationAndRefresh {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][ValidateSet('Succeeded','Failed','Cancelled','Interrupted')][string]$Status,
        [string]$Stage,
        [string]$Detail
    )
    $Operation = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id $Id -Status $Status -Stage $Stage -Detail $Detail
    Refresh-OperationCenter
    if ($Status -ne 'Cancelled') { Show-OperationNotification $Operation }
    return $Operation
}

function Invoke-TrackedSynchronousAction {
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$ServerId = '',
        [string]$Stage = 'PRÉPARATION',
        [string]$Detail = '',
        [string]$RetryAction = '',
        $Metadata = $null,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    $LogPath = Get-OperationLogPath $Type
    $Tracked = New-RustTrackedOperation -ServerRoot $ServerRoot -Type $Type -Title $Title -ServerId $ServerId -Stage $Stage -Detail $Detail -RetryAction $RetryAction -CanCancel $false -LogPath $LogPath -ErrorLogPath $LogPath -Metadata $Metadata
    Write-TrackedOperationLog $LogPath "DÉBUT — $Title"
    Refresh-OperationCenter
    $Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Render)
    try {
        $Output = @(& $Action)
        Write-TrackedOperationLog $LogPath 'TERMINÉ — opération réussie.'
        $Completed = Complete-TrackedOperationAndRefresh -Id ([string]$Tracked.id) -Status Succeeded -Stage 'TERMINÉ' -Detail $(if ($Detail) { $Detail } else { 'Opération terminée avec succès.' })
        if ($Output.Count -eq 1) { return $Output[0] }
        return $Output
    }
    catch {
        $Message = $_.Exception.Message
        Write-TrackedOperationLog $LogPath ("ÉCHEC — " + $Message)
        $null = Complete-TrackedOperationAndRefresh -Id ([string]$Tracked.id) -Status Failed -Stage 'ÉCHEC' -Detail $Message
        throw
    }
}

function Sync-ControlCenterUpdateOperation([switch]$Force) {
    $Operation = $script:UpdateOperation
    if (-not $Operation -or -not $Operation.Id) { return }
    if (-not $Force -and ((Get-Date) - $script:OperationLastPersistAt).TotalSeconds -lt 1.2) { return }
    $script:OperationLastPersistAt = Get-Date
    $Status = if ([string]$Operation.State -eq 'Running') { 'Running' } elseif ([string]$Operation.State -eq 'Completed') { 'Succeeded' } else { 'Failed' }
    if ($Status -eq 'Running') {
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.Id) -Changes @{
            progress = [double]$Operation.Percent
            stage = [string]$Operation.Stage
            detail = [string]$Operation.Detail
            processId = $(try { [int]$Operation.Process.Id } catch { 0 })
        }
    }
    else {
        $Stage = [string]$Operation.Stage
        $Detail = [string]$Operation.Detail
        $Tracked = Get-TrackedOperationById ([string]$Operation.Id)
        if ($Tracked -and [string]$Tracked.status -eq 'Running') {
            $null = Complete-TrackedOperationAndRefresh -Id ([string]$Operation.Id) -Status $Status -Stage $Stage -Detail $Detail
        }
    }
    Refresh-OperationCenter
}

function Update-TrackedServerStartOperations {
    $RunningProcesses = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $Operations = @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object { [string]$_.status -eq 'Running' -and [string]$_.type -eq 'ServerStart' })
    foreach ($Operation in $Operations) {
        $Identity = [string](Get-OperationMetadataValue $Operation 'identity' '')
        $InstanceProcess = @($RunningProcesses | Where-Object { [string]$_.Identity -eq $Identity }) | Select-Object -First 1
        if ($InstanceProcess) {
            $Detail = "$($InstanceProcess.DisplayName) est démarré sur le port UDP $($InstanceProcess.ServerPort)."
            $null = Complete-TrackedOperationAndRefresh -Id ([string]$Operation.id) -Status Succeeded -Stage 'SERVEUR ACTIF' -Detail $Detail
            continue
        }
        $Elapsed = Get-OperationElapsedSeconds $Operation
        $LauncherAlive = $false
        if ([int]$Operation.processId -gt 0) {
            $LauncherAlive = $null -ne (Get-Process -Id ([int]$Operation.processId) -ErrorAction SilentlyContinue)
        }
        if (-not $LauncherAlive -and $Elapsed -ge 8) {
            $ErrorDetail = 'Le lanceur a été arrêté avant que RustDedicated devienne actif.'
            if ([string]$Operation.errorLogPath -and (Test-Path -LiteralPath ([string]$Operation.errorLogPath))) {
                $Tail = @((Get-Content -LiteralPath ([string]$Operation.errorLogPath) -Tail 8 -ErrorAction SilentlyContinue) | Where-Object { $_ })
                if ($Tail.Count) { $ErrorDetail = [string]$Tail[-1] }
            }
            $null = Complete-TrackedOperationAndRefresh -Id ([string]$Operation.id) -Status Failed -Stage 'ÉCHEC DU DÉMARRAGE' -Detail $ErrorDetail
            continue
        }
        $Progress = [math]::Min(90,[math]::Max(4,4 + ($Elapsed * 1.6)))
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Changes @{
            progress = [double]$Progress
            stage = 'CHARGEMENT DU SERVEUR'
            detail = 'RustDedicated charge la carte et initialise les services...'
        }
    }
}

function Import-LegacyUpdateOperations {
    $Existing = @(Get-RustTrackedOperations -ServerRoot $ServerRoot)
    if ($Existing.Count) { return }
    $LogDirectory = Join-Path $ServerRoot 'logs'
    if (-not (Test-Path -LiteralPath $LogDirectory)) { return }
    $Logs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'update-????????-??????.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 8)
    foreach ($Log in ($Logs | Sort-Object LastWriteTime)) {
        $Text = (Get-Content -LiteralPath $Log.FullName -Tail 220 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n"
        $Success = $Text -match 'RCC_PROGRESS\|100\|TERMINE\|'
        $ErrorPath = Join-Path $Log.DirectoryName ($Log.BaseName + '-error.log')
        $Tracked = New-RustTrackedOperation -ServerRoot $ServerRoot -Type Update -Title 'Mise à jour de Rust Dedicated' -Stage 'IMPORT HISTORIQUE' -Detail 'Opération importée depuis un journal existant.' -RetryAction update -CanCancel $false -LogPath $Log.FullName -ErrorLogPath $ErrorPath
        $Status = if ($Success) { 'Succeeded' } else { 'Failed' }
        $Stage = if ($Success) { 'TERMINÉ' } else { 'ÉCHEC' }
        $Completed = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Status $Status -Stage $Stage -Detail $(if ($Success) { 'Rust Dedicated a été mis à jour avec succès.' } else { 'Cette ancienne tentative ne contient pas de marqueur de réussite.' })
        $Started = $Log.CreationTimeUtc
        if ($Log.BaseName -match '^update-(\d{8}-\d{6})$') {
            try { $Started = [datetime]::ParseExact($Matches[1],'yyyyMMdd-HHmmss',[Globalization.CultureInfo]::InvariantCulture).ToUniversalTime() } catch { }
        }
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Changes @{
            startedUtc = $Started.ToString('o')
            completedUtc = $Log.LastWriteTimeUtc.ToString('o')
            durationSeconds = [math]::Max(0,[int]($Log.LastWriteTimeUtc - $Started).TotalSeconds)
            notificationShown = $true
        }
    }
}

function Restore-TrackedOperations {
    if ($CapturePath) { return }
    $Operations = @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object status -eq 'Running')
    foreach ($Operation in $Operations) {
        if ([string]$Operation.type -eq 'ServerStart') { continue }
        if ([string]$Operation.type -in @('Update','CarbonInstall','OxideInstall','IsolationInstall','PluginCatalogInstall','FriendTest')) {
            $Process = if ([int]$Operation.processId -gt 0) { Get-Process -Id ([int]$Operation.processId) -ErrorAction SilentlyContinue } else { $null }
            $ProcessMatches = $false
            if ($Process -and [string]$Process.ProcessName -match '^powershell$') {
                try {
                    $Started = Get-OperationDate ([string]$Operation.startedUtc)
                    $ProcessMatches = [math]::Abs(($Process.StartTime - $Started).TotalSeconds) -lt 20
                }
                catch { }
            }
            if ($ProcessMatches -and [string]$Operation.type -in @('IsolationInstall','PluginCatalogInstall','FriendTest')) { continue }
            if ($ProcessMatches) {
                $script:UpdateOperation = [pscustomobject]@{
                    Id = [string]$Operation.id; Process = $Process; OutputPath = [string]$Operation.logPath; ErrorPath = [string]$Operation.errorLogPath
                    State = 'Running'; Percent = [double]$Operation.progress; Stage = [string]$Operation.stage; Detail = [string]$Operation.detail
                }
                continue
            }
            $Tail = if ([string]$Operation.logPath -and (Test-Path -LiteralPath ([string]$Operation.logPath))) { (Get-Content -LiteralPath ([string]$Operation.logPath) -Tail 220 -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
            if ($Tail -match 'RCC_PROGRESS\|100\|TERMINE\|') {
                $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Succeeded -Stage 'TERMINÉ' -Detail 'Rust Dedicated est à jour.'
            }
            else {
                $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Interrupted -Stage 'INTERROMPUE' -Detail 'Cette opération a été retrouvée sans processus actif. Tu peux la réessayer.'
            }
            continue
        }
        $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Interrupted -Stage 'INTERROMPUE' -Detail 'Cette opération locale a été interrompue avant sa confirmation finale.'
    }
}

function Initialize-OperationCenter {
    if (-not $CapturePath) {
        Import-LegacyUpdateOperations
        Restore-TrackedOperations
        Initialize-OperationNotifications
        Update-TrackedServerStartOperations
    }
    Refresh-OperationCenter
    Show-ControlCenterUpdateProgress
}

function Assert-OperationLogPath([string]$Path) {
    if (-not $Path) { throw 'Aucun journal associé à cette opération.' }
    $FullPath = [IO.Path]::GetFullPath($Path)
    $SafeRoot = [IO.Path]::GetFullPath($ServerRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $FullPath.StartsWith($SafeRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Le journal demandé se trouve hors du dossier serveur.' }
    if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { throw 'Le journal associé est introuvable.' }
    return $FullPath
}

function Open-TrackedOperationLog($Operation) {
    if (-not $Operation) { throw 'Sélectionne une opération.' }
    $Path = Assert-OperationLogPath ([string]$Operation.logPath)
    Start-Process -FilePath notepad.exe -ArgumentList ('"' + $Path + '"')
}

function Open-SelectedOperationDiagnostic {
    $Operation = Get-SelectedTrackedOperation
    if (-not $Operation) { throw 'Sélectionne une opération.' }
    $Path = Assert-OperationLogPath ([string]$Operation.logPath)
    if ($script:InterfaceMode -eq 'simple') { Apply-InterfaceMode -Mode advanced }
    Open-ControlCenterTab 10
    Refresh-LogFiles
    $Match = @($Ui.LogFileCombo.ItemsSource | Where-Object { [string]$_.Path -eq $Path }) | Select-Object -First 1
    if ($Match) { $Ui.LogFileCombo.SelectedItem = $Match }
    Load-SelectedLog
    Set-Activity 'Diagnostic ouvert sur le journal sélectionné.'
}

function Cancel-ActiveTrackedOperation {
    $Operation = Get-RustActiveTrackedOperation -ServerRoot $ServerRoot
    if (-not $Operation) { throw 'Aucune opération en cours.' }
    if (-not [bool]$Operation.canCancel) { throw 'Cette opération ne peut pas être annulée en sécurité.' }
    if ([string]$Operation.type -eq 'FriendTest') { Request-FriendTestCancellation; return }
    if (-not (Confirm-Action "Annuler « $($Operation.title) » ?`n`nLes processus appartenant uniquement à cette opération seront arrêtés." 'Annuler cette opération')) { return }
    $PidValue = [int]$Operation.processId
    if ([string]$Operation.type -in @('Update','CarbonInstall','OxideInstall','IsolationInstall','PluginCatalogInstall') -and $PidValue -gt 0) {
        $Parent = Get-Process -Id $PidValue -ErrorAction SilentlyContinue
        if (-not $Parent -or [string]$Parent.ProcessName -notmatch '^powershell$') { throw 'Le processus de mise à jour ne correspond plus à cette opération.' }
        $Started = Get-OperationDate ([string]$Operation.startedUtc)
        if ([math]::Abs(($Parent.StartTime - $Started).TotalSeconds) -ge 20) { throw 'Le PID de mise à jour a été réutilisé : annulation refusée par sécurité.' }
        $Children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $PidValue" -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -in @('steamcmd.exe','powershell.exe') })
        foreach ($Child in $Children) { Stop-Process -Id ([int]$Child.ProcessId) -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue
        if ($script:UpdateOperation -and [string]$script:UpdateOperation.Id -eq [string]$Operation.id) { $script:UpdateOperation = $null }
    }
    elseif ([string]$Operation.type -eq 'ServerStart') {
        $Identity = [string](Get-OperationMetadataValue $Operation 'identity' '')
        $Targets = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq $Identity)
        foreach ($Target in $Targets) { Stop-Process -Id ([int]$Target.ProcessId) -Force -ErrorAction SilentlyContinue }
        if ($PidValue -gt 0) {
            $Launcher = Get-Process -Id $PidValue -ErrorAction SilentlyContinue
            if ($Launcher -and [string]$Launcher.ProcessName -match '^powershell$') { Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue }
        }
    }
    $null = Complete-TrackedOperationAndRefresh -Id ([string]$Operation.id) -Status Cancelled -Stage 'ANNULÉE' -Detail 'Opération annulée manuellement.'
    Show-ControlCenterUpdateProgress
    Set-Activity 'Opération annulée.'
}

function Retry-SelectedOperation {
    $Operation = Get-SelectedTrackedOperation
    if (-not $Operation) { throw 'Sélectionne une opération.' }
    switch ([string]$Operation.retryAction) {
        'update' { Start-ControlCenterUpdate }
        'carbon' { Start-ControlCenterUpdate -InstallCarbon }
        'oxide' { Start-ControlCenterUpdate -InstallOxide }
        'server-start' {
            $InstanceId = [string](Get-OperationMetadataValue $Operation 'instanceId' '')
            if (-not $InstanceId) { $InstanceId = [string]$Operation.serverId }
            Start-RustInstance -Id $InstanceId
        }
        'wipe' {
            $Identity = [string](Get-OperationMetadataValue $Operation 'identity' '')
            $Type = [string](Get-OperationMetadataValue $Operation 'wipeType' 'map')
            if (-not (Confirm-Action "Réessayer le wipe $Type de $Identity ?`nUne nouvelle sauvegarde sera créée." 'Réessayer le wipe')) { return }
            Invoke-TrackedWipe -Identity $Identity -Type $Type -ResetPluginData ([bool](Get-OperationMetadataValue $Operation 'resetPluginData' $false)) -CleanGeneratedMaps ([bool](Get-OperationMetadataValue $Operation 'cleanGeneratedMaps' $false))
        }
        'map-generate' {
            $Identity = [string](Get-OperationMetadataValue $Operation 'identity' '')
            if (-not (Confirm-Action "Réessayer la préparation de la carte pour $Identity ?" 'Réessayer la carte')) { return }
            Invoke-TrackedMapGeneration -Identity $Identity
        }
        'plugin-toggle' {
            $FileBase = [string](Get-OperationMetadataValue $Operation 'fileBase' '')
            $Enabled = [bool](Get-OperationMetadataValue $Operation 'enabled' $true)
            if (-not (Confirm-Disruption "Réessayer la modification de $FileBase")) { return }
            Invoke-TrackedPluginToggle -FileBase $FileBase -Enabled $Enabled
        }
        'plugin-import' {
            $SourcePath = [string](Get-OperationMetadataValue $Operation 'sourcePath' '')
            if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Le fichier source du plugin est introuvable.' }
            Invoke-TrackedPluginImport -SourcePath $SourcePath
        }
        'isolation-install' {
            $InstanceId=[string](Get-OperationMetadataValue $Operation 'instanceId' '')
            $Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $InstanceId
            if(-not$Instance){throw 'Instance cible introuvable.'}
            $Row=@($Ui.InstanceGrid.ItemsSource|Where-Object Id -eq $InstanceId)|Select-Object -First 1
            if($Row){$Ui.InstanceGrid.SelectedItem=$Row}
            $Ui.InstanceIsolationCarbonCheck.IsChecked=[bool](Get-OperationMetadataValue $Operation 'includeCarbon' $false)
            Start-SelectedIsolatedRuntimeInstall
        }
        'plugin-catalog-install' {
            $PluginId=[string](Get-OperationMetadataValue $Operation 'pluginId' '')
            Open-ControlCenterTab 21;Refresh-AvailablePluginCatalog
            $Row=@($Ui.AvailablePluginGrid.ItemsSource|Where-Object Id -eq $PluginId)|Select-Object -First 1
            if(-not$Row){throw 'Plugin absent du catalogue actuel.'};$Ui.AvailablePluginGrid.SelectedItem=$Row;Start-CatalogPluginInstall
        }
        'friend-test' { Start-FriendTest }
        default { throw 'Cette opération ne propose pas de réessai automatique.' }
    }
}

function Get-ControlCenterLocale([string]$Code) {
    $Path = Join-Path $PSScriptRoot ("locales\$Code.json")
    if (-not (Test-Path -LiteralPath $Path)) { $Path = Join-Path $PSScriptRoot 'locales\fr-FR.json' }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

$script:StaticLocalizationEntries=@()
$script:EnglishUiDictionary=$null

function Initialize-StaticLocalization {
    $Entries=New-Object Collections.Generic.List[object]
    $Seen=New-Object 'Collections.Generic.HashSet[int]'
    $Queue=New-Object Collections.Queue;$Queue.Enqueue($Window)
    while($Queue.Count){
        $Object=$Queue.Dequeue();if($null-eq$Object){continue};$Hash=[Runtime.CompilerServices.RuntimeHelpers]::GetHashCode($Object);if($Seen.Contains($Hash)){continue};$null=$Seen.Add($Hash)
        if($Object-is[Windows.Controls.TextBlock]-and[string]$Object.Text){$Entries.Add([pscustomobject]@{Object=$Object;Property='Text';Original=[string]$Object.Text})}
        if($Object-is[Windows.Controls.ContentControl]-and$Object.Content-is[string]-and[string]$Object.Content){$Entries.Add([pscustomobject]@{Object=$Object;Property='Content';Original=[string]$Object.Content})}
        if($Object-is[Windows.Controls.HeaderedContentControl]-and$Object.Header-is[string]-and[string]$Object.Header){$Entries.Add([pscustomobject]@{Object=$Object;Property='Header';Original=[string]$Object.Header})}
        if($Object-is[Windows.FrameworkElement]-and$Object.ToolTip-is[string]-and[string]$Object.ToolTip){$Entries.Add([pscustomobject]@{Object=$Object;Property='ToolTip';Original=[string]$Object.ToolTip})}
        if($Object-is[Windows.Controls.DataGrid]){foreach($Column in $Object.Columns){if($Column.Header-is[string]-and[string]$Column.Header){$Entries.Add([pscustomobject]@{Object=$Column;Property='Header';Original=[string]$Column.Header})}}}
        if($Object-is[Windows.DependencyObject]){foreach($Child in [Windows.LogicalTreeHelper]::GetChildren($Object)){if($Child-is[Windows.DependencyObject]){$Queue.Enqueue($Child)}}}
    }
    $script:StaticLocalizationEntries=[object[]]$Entries.ToArray()
}

function ConvertTo-EnglishUiText([string]$Text){
    if(-not$script:EnglishUiDictionary){$Path=Join-Path $PSScriptRoot 'locales\ui-en-US.json';$script:EnglishUiDictionary=Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}
    $Exact=$script:EnglishUiDictionary.exact.PSObject.Properties|Where-Object Name -eq $Text|Select-Object -First 1
    if($Exact){return [string]$Exact.Value}
    $Result=$Text
    foreach($Replacement in @($script:EnglishUiDictionary.replacements|Sort-Object{([string]$_.from).Length}-Descending)){$Result=$Result.Replace([string]$Replacement.from,[string]$Replacement.to)}
    return $Result
}

function Get-LocalizedUiText([string]$French,[string]$English){
    if($script:CurrentUiLanguage-eq'en-US'){return $English}
    return $French
}

function Apply-StaticLocalization([string]$Code){
    if(-not$script:StaticLocalizationEntries.Count){Initialize-StaticLocalization}
    foreach($Entry in $script:StaticLocalizationEntries){$Value=if($Code-eq'en-US'){ConvertTo-EnglishUiText ([string]$Entry.Original)}else{[string]$Entry.Original};$Entry.Object.($Entry.Property)=$Value}
}

function Set-LocalizedChoiceSources([ValidateSet('fr-FR','en-US')][string]$Code){
    $English=$Code-eq'en-US'
    $ScheduleAction=[string]$Ui.ScheduleActionCombo.SelectedValue
    $ScheduleRecurrence=[string]$Ui.ScheduleRecurrenceCombo.SelectedValue
    $ScheduleDay=[string]$Ui.ScheduleDayCombo.SelectedValue
    $Isolation=[string]$Ui.InstanceIsolationCombo.SelectedValue
    $RemoteBind=[string]$Ui.RemoteBindCombo.SelectedValue
    $MapType=Get-SelectedText $Ui.MapTypeCombo
    $WizardMapType=Get-SelectedText $Ui.WizardMapTypeCombo
    $SimpleCategory=[math]::Max(0,$Ui.SimpleModsCategoryCombo.SelectedIndex)
    $SimpleState=[math]::Max(0,$Ui.SimpleModsStateCombo.SelectedIndex)
    $CatalogCategory=[math]::Max(0,$Ui.CatalogCategoryCombo.SelectedIndex)
    $Ui.ScheduleActionCombo.ItemsSource=@(
        [pscustomobject]@{Code='Backup';Label=if($English){'Full backup'}else{'Sauvegarde complète'}},
        [pscustomobject]@{Code='MapWipe';Label=if($English){'Map wipe'}else{'Wipe carte'}},
        [pscustomobject]@{Code='FullWipe';Label='Full wipe'})
    $Ui.ScheduleRecurrenceCombo.ItemsSource=@(
        [pscustomobject]@{Code='Daily';Label=if($English){'Every day'}else{'Chaque jour'}},
        [pscustomobject]@{Code='Weekly';Label=if($English){'Every week'}else{'Chaque semaine'}},
        [pscustomobject]@{Code='Interval';Label=if($English){'Every X hours'}else{'Toutes les X heures'}})
    $DayLabels=if($English){@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')}else{@('Lundi','Mardi','Mercredi','Jeudi','Vendredi','Samedi','Dimanche')}
    $DayCodes=@('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')
    $Ui.ScheduleDayCombo.ItemsSource=@(for($Index=0;$Index-lt7;$Index++){[pscustomobject]@{Code=$DayCodes[$Index];Label=$DayLabels[$Index]}})
    $Ui.InstanceIsolationCombo.ItemsSource=@(
        [pscustomobject]@{Code='shared';Label=if($English){'Shared runtime (vanilla / 1 Carbon)'}else{'Runtime partagé (vanilla / 1 Carbon)'}},
        [pscustomobject]@{Code='full';Label=if($English){'Fully isolated runtime (multi Carbon)'}else{'Runtime complet isolé (multi Carbon)'}})
    $Ui.RemoteBindCombo.ItemsSource=@(
        [pscustomobject]@{Code='127.0.0.1';Label=if($English){'This PC only (recommended)'}else{'Ce PC uniquement (recommandé)'}},
        [pscustomobject]@{Code='0.0.0.0';Label=if($English){'Local network / VPN (expert)'}else{'Réseau local / VPN (expert)'}})
    $MapTypes=@([pscustomobject]@{Code='Procedurale';Label=if($English){'Procedural'}else{'Procédurale'}},[pscustomobject]@{Code='Custom URL';Label='Custom URL'})
    $Ui.MapTypeCombo.ItemsSource=$MapTypes
    if($Ui.WizardMapTypeCombo.ItemsSource){$Ui.WizardMapTypeCombo.ItemsSource=$MapTypes}
    $Ui.SimpleModsCategoryCombo.ItemsSource=if($English){@('All categories','Game modes','Gameplay','Economy','Administration','Utilities','Other')}else{@('Toutes les catégories','Modes de jeu','Gameplay','Économie','Administration','Utilitaires','Autres')}
    $Ui.SimpleModsStateCombo.ItemsSource=if($English){@('All states','Enabled','Disabled','Needs review')}else{@('Tous les états','Actifs','Désactivés','À vérifier')}
    $Ui.CatalogCategoryCombo.ItemsSource=if($English){@('All','Administration','Gameplay','Economy','Utility','Other')}else{@('Toutes','Administration','Gameplay','Économie','Utilitaire','Autre')}
    if($Ui.CatalogSourceNameBox.Text-in@('Ma source','My source')){$Ui.CatalogSourceNameBox.Text=if($English){'My source'}else{'Ma source'}}
    $Ui.ScheduleActionCombo.SelectedValue=if($ScheduleAction){$ScheduleAction}else{'Backup'}
    $Ui.ScheduleRecurrenceCombo.SelectedValue=if($ScheduleRecurrence){$ScheduleRecurrence}else{'Weekly'}
    $Ui.ScheduleDayCombo.SelectedValue=if($ScheduleDay){$ScheduleDay}else{'Thursday'}
    $Ui.InstanceIsolationCombo.SelectedValue=$Isolation
    $Ui.RemoteBindCombo.SelectedValue=$RemoteBind
    $Ui.MapTypeCombo.SelectedValue=if($MapType){$MapType}else{'Procedurale'}
    if($Ui.WizardMapTypeCombo.ItemsSource){$Ui.WizardMapTypeCombo.SelectedValue=if($WizardMapType){$WizardMapType}else{'Procedurale'}}
    $Ui.SimpleModsCategoryCombo.SelectedIndex=$SimpleCategory
    $Ui.SimpleModsStateCombo.SelectedIndex=$SimpleState
    $Ui.CatalogCategoryCombo.SelectedIndex=$CatalogCategory
}

function Apply-ControlCenterLanguage([string]$Code,[switch]$NoSave) {
    if ($Code -notin @('fr-FR','en-US')) { $Code = 'fr-FR' }
    $script:CurrentUiLanguage = $Code
    $Locale = Get-ControlCenterLocale $Code
    Apply-StaticLocalization -Code $Code
    $Window.Title = [string]$Locale.appTitle
    $Ui.HeaderTitleText.Text = [string]$Locale.headerTitle
    $Ui.HeaderSubtitleText.Text = [string]$Locale.headerSubtitle
    $Ui.InstancesPageTitle.Text = [string]$Locale.instancesTitle
    $Ui.InstancesPageSubtitle.Text = [string]$Locale.instancesSubtitle
    $Ui.InstanceMultiWarningText.Text = [string]$Locale.multiWarning
    $NavigationLabels = @($Locale.navigation)
    $NavigationGroups = @($Locale.navigationGroups)
    # Les entetes de groupe n'ont pas de Tag : elles sont traduites a part, et
    # les entrees reelles gardent l'ordre du tableau navigation.
    $LabelIndex = 0
    foreach ($Item in $Ui.Navigation.Items) {
        if ($null -eq $Item.Tag) { continue }
        if ($LabelIndex -ge $NavigationLabels.Count) { break }
        $Item.Content = [string]$NavigationLabels[$LabelIndex]
        $LabelIndex++
    }
    $GroupHeaders = @('NavGroupServerHeader','NavGroupWorldHeader','NavGroupGameHeader')
    for ($Index = 0; $Index -lt [Math]::Min($NavigationGroups.Count,$GroupHeaders.Count); $Index++) {
        if ($Ui[$GroupHeaders[$Index]]) { $Ui[$GroupHeaders[$Index]].Content = [string]$NavigationGroups[$Index] }
    }
    # Les boutons de sous-onglets sont crees a la volee : la table de
    # traduction par texte exact ne les voit pas, d'ou leurs propres libelles.
    $script:SubTabLabels = @{}
    if ($Locale.PSObject.Properties.Name -contains 'subTabs') {
        foreach ($Property in $Locale.subTabs.PSObject.Properties) { $script:SubTabLabels[[int]$Property.Name] = [string]$Property.Value }
    }
    Update-SubNav
    $Ui.DashLocalButton.Content = if ($Locale.PSObject.Properties.Name -contains 'dashboardStart') { [string]$Locale.dashboardStart } else { [string]$Locale.launchSelected }
    $Ui.DashOnlineButton.Content = [string]$Locale.openManager
    $Ui.ServerLocalButton.Content = [string]$Locale.launchSelected
    $Ui.ServerOnlineButton.Content = [string]$Locale.launchEnabled
    $Ui.ServerStopButton.Content = [string]$Locale.stopSelected
    $Ui.StopAllInstancesButton.Content = [string]$Locale.stopAll
    $Ui.ServerJoinButton.Content = [string]$Locale.joinSelected
    $Ui.NewInstanceButton.Content = [string]$Locale.newInstance
    $Ui.DuplicateInstanceButton.Content = [string]$Locale.duplicateInstance
    $Ui.SaveInstanceButton.Content = [string]$Locale.saveInstance
    $Ui.RemoveInstanceButton.Content = [string]$Locale.removeInstance
    if ($Locale.PSObject.Properties.Name -contains 'diagnostic') {
        $Ui.GlobalDiagnosticTitleText.Text = [string]$Locale.diagnostic.title
        $Ui.GlobalDiagnosticSubtitleText.Text = [string]$Locale.diagnostic.subtitle
        $Ui.RunGlobalDiagnosticButton.Content = [string]$Locale.diagnostic.run
        $Ui.RepairGlobalDiagnosticButton.Content = [string]$Locale.diagnostic.repair
        $Ui.ExportGlobalDiagnosticButton.Content = [string]$Locale.diagnostic.export
    }
    if ($Locale.PSObject.Properties.Name -contains 'onboarding') {
        $Ui.OnboardingTitleText.Text = [string]$Locale.onboarding.title
        $Ui.OnboardingSubtitleText.Text = [string]$Locale.onboarding.subtitle
        $Ui.OnboardingFinishButton.Content = [string]$Locale.onboarding.finish
        $Ui.OnboardingLaterButton.Content = [string]$Locale.onboarding.later
        $Ui.OnboardingDiagnosticButton.Content = [string]$Locale.onboarding.diagnostic
        if ($Locale.onboarding.PSObject.Properties.Name -contains 'repair') { $Ui.OnboardingRepairButton.Content = [string]$Locale.onboarding.repair }
    }
    $IsSimple=$script:InterfaceMode-eq'simple';$English=$Code-eq'en-US'
    $Ui.SidebarModeLabel.Text=if($IsSimple){if($English){'SIMPLE MODE'}else{'MODE SIMPLE'}}else{if($English){'SERVER MANAGEMENT'}else{'GESTION DU SERVEUR'}}
    $Ui.InterfaceModeButton.Content=if($IsSimple){if($English){'ADVANCED MODE'}else{'MODE AVANCÉ'}}else{if($English){'SIMPLE MODE'}else{'MODE SIMPLE'}}
    if($script:ChoiceLocalizationReady){Set-LocalizedChoiceSources -Code $Code}
    if (-not $NoSave) { Set-RustControlCenterLanguage -ServerRoot $ServerRoot -Language $Code }
}

# Navigation avancee a deux niveaux. Chaque section est une entree du menu de
# gauche ; ses sous-onglets s'affichent en barre au-dessus de la page. Les
# onglets eux-memes n'ont pas bouge : seul le chemin pour y arriver change.
# Tabs = sous-onglets affiches, dans l'ordre. Extra = pages rattachees a la
# section sans sous-onglet (assistant de creation, vues du mode simple...).
$script:NavSections = @(
    [pscustomobject]@{ Key='dashboard'; Tabs=@(0);        Labels=@('Vue d''ensemble');                                                Extra=@(18) }
    [pscustomobject]@{ Key='servers';   Tabs=@(1);        Labels=@('Instances');                                                      Extra=@(15,13) }
    [pscustomobject]@{ Key='network';   Tabs=@(9,20,12);  Labels=@('Réseau & ports','Accès distant','Test avec un ami');               Extra=@() }
    [pscustomobject]@{ Key='world';     Tabs=@(2,16,3,23); Labels=@('Cartes & seeds','Taux & multiplicateurs','Wipes & sauvegardes','Lobby & cartes'); Extra=@() }
    [pscustomobject]@{ Key='plugins';   Tabs=@(4,21,5);   Labels=@('Extensions','Catalogue','Modes de jeu');                          Extra=@(11) }
    [pscustomobject]@{ Key='settings';  Tabs=@(6);        Labels=@('Configuration');                                                  Extra=@() }
    [pscustomobject]@{ Key='players';   Tabs=@(7,8);      Labels=@('Modération','Statistiques');                                      Extra=@() }
    [pscustomobject]@{ Key='health';    Tabs=@(19,22,17); Labels=@('Supervision','Santé du PC','Diagnostic global');                  Extra=@() }
    [pscustomobject]@{ Key='ops';       Tabs=@(14,10);    Labels=@('Opérations','Logs & maintenance');                                Extra=@() }
)
# Modes de jeu reste masque tant qu'aucun plugin de mode n'est detecte, comme
# l'etait son ancienne entree de menu.
$script:SubTabHidden = New-Object 'System.Collections.Generic.HashSet[int]'
[void]$script:SubTabHidden.Add(5)
$script:SectionLastTab = @{}
$script:SubTabLabels = @{}
$script:NavGuard = $false

function Get-NavSection([int]$Tab) {
    foreach ($Section in $script:NavSections) {
        if ($Section.Tabs -contains $Tab -or $Section.Extra -contains $Tab) { return $Section }
    }
    return $null
}

function Get-NavSectionItem($Section) {
    if (-not $Section) { return $null }
    $Primary = [int]$Section.Tabs[0]
    foreach ($Item in $Ui.Navigation.Items) {
        if ($null -ne $Item.Tag -and [int]$Item.Tag -eq $Primary) { return $Item }
    }
    return $null
}

function Invoke-TabActivated([int]$Tab) {
    # Rafraichissements propres a chaque page, autrefois portes par le seul
    # gestionnaire du menu : un clic sur un sous-onglet doit les declencher
    # aussi, sinon la page s'affiche avec des donnees perimees.
    if ($Tab -eq 9 -and -not $script:NetworkDiagnosticRequested) {
        $script:NetworkDiagnosticRequested = $true
        Invoke-UiAction { Refresh-NetworkDiagnostics }
    }
    if ($Tab -eq 16) { Invoke-UiAction { Refresh-Rates } }
    if ($Tab -eq 14) { Invoke-UiAction { Refresh-OperationCenter } }
    if ($Tab -eq 17) { Invoke-UiAction { Refresh-GlobalDiagnostics } }
    if ($Tab -eq 19) { Invoke-UiAction { Refresh-Supervision -IncludeRcon } }
    if ($Tab -eq 20) { Invoke-UiAction { Refresh-RemoteAccess } }
    if ($Tab -eq 21) { Invoke-UiAction { Refresh-AvailablePluginCatalog } }
    if ($Tab -eq 22) { Invoke-UiAction { Refresh-HostHealth } }
    if ($Tab -eq 12) { Invoke-UiAction { Refresh-SimpleFriends } }
    if ($Tab -eq 23) { Invoke-UiAction { Load-LobbyEditor } }
    if ($Tab -eq 3 -and -not $script:MaintenanceEditorDirty) { Invoke-UiAction { Refresh-MaintenanceSchedules -SelectId $script:SelectedScheduleId } }
}

function Update-SubNav {
    if (-not $Ui -or -not $Ui.SubNavBar -or -not $Ui.SubNavPanel) { return }
    if ($script:InterfaceMode -ne 'advanced') {
        $Ui.SubNavBar.Visibility = [Windows.Visibility]::Collapsed
        return
    }
    $Current = [int]$Ui.MainTabs.SelectedIndex
    $Section = Get-NavSection $Current
    if (-not $Section) {
        $Ui.SubNavBar.Visibility = [Windows.Visibility]::Collapsed
        return
    }

    # La surbrillance du menu suit l'onglet reel, quel que soit le chemin pris
    # pour y arriver : bouton d'une page, assistant, raccourci du tableau de bord.
    $Item = Get-NavSectionItem $Section
    if ($Item -and -not [object]::ReferenceEquals($Ui.Navigation.SelectedItem, $Item)) {
        $script:NavGuard = $true
        try { $Ui.Navigation.SelectedItem = $Item }
        finally { $script:NavGuard = $false }
    }
    if ($Section.Tabs -contains $Current) { $script:SectionLastTab[$Section.Key] = $Current }

    $Ui.SubNavPanel.Children.Clear()
    $Visible = @($Section.Tabs | Where-Object { -not $script:SubTabHidden.Contains([int]$_) })
    if ($Visible.Count -le 1) {
        $Ui.SubNavBar.Visibility = [Windows.Visibility]::Collapsed
        return
    }

    $SubStyle = $Window.FindResource('SubNavButton')
    for ($Index = 0; $Index -lt $Section.Tabs.Count; $Index++) {
        $Tab = [int]$Section.Tabs[$Index]
        if ($script:SubTabHidden.Contains($Tab)) { continue }
        $Label = if ($script:SubTabLabels.ContainsKey($Tab)) { [string]$script:SubTabLabels[$Tab] } else { [string]$Section.Labels[$Index] }
        $Button = New-Object Windows.Controls.Button
        $Button.Style = $SubStyle
        $Button.Content = $Label.ToUpperInvariant()
        $Button.Tag = $Tab
        if ($Tab -eq $Current) {
            $Button.Foreground = $BrushConverter.ConvertFromString('#F5E8D6')
            $Button.BorderBrush = $BrushConverter.ConvertFromString('#D65332')
        }
        $Button.Add_Click({
            param($Sender)
            $TargetTab = [int]$Sender.Tag
            Invoke-UiAction { Show-AdvancedTab $TargetTab }
        })
        [void]$Ui.SubNavPanel.Children.Add($Button)
    }
    $Ui.SubNavBar.Visibility = [Windows.Visibility]::Visible
}

function Show-AdvancedTab([int]$Tab) {
    # Point d'entree unique vers une page du mode avance : section, onglet,
    # barre et rafraichissement, dans cet ordre.
    $Section = Get-NavSection $Tab
    $Item = Get-NavSectionItem $Section
    if ($Item) {
        $script:NavGuard = $true
        try { $Ui.Navigation.SelectedItem = $Item }
        finally { $script:NavGuard = $false }
    }
    $Ui.MainTabs.SelectedIndex = $Tab
    Update-SubNav
    Invoke-TabActivated $Tab
}

function Select-AdvancedNav {
    # Garde son nom et sa signature : une quinzaine d'appels existants s'y
    # fient. Il passe maintenant par la section, donc un onglet qui n'est pas
    # en tete de section (Taux, Statistiques...) est atteint correctement au
    # lieu de renvoyer sur le premier sous-onglet.
    param([Parameter(Mandatory)][int]$Tab)
    Show-AdvancedTab $Tab
}

$script:InterfaceMode = 'simple'

function Apply-InterfaceMode([ValidateSet('simple','advanced')][string]$Mode,[switch]$NoSave) {
    $script:InterfaceMode = $Mode
    $IsSimple = $Mode -eq 'simple'
    $Ui.SimpleNavigation.Visibility = if ($IsSimple) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.Navigation.Visibility = if ($IsSimple) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Ui.SimpleHelpButton.Visibility = if ($IsSimple) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.AdvancedConnectionCard.Visibility = if ($IsSimple) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Ui.LanguageCombo.Visibility = if ($IsSimple) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Ui.HeaderStartButton.Visibility = if ($IsSimple) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Ui.SimpleHomeScroll.Visibility = if ($IsSimple) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.AdvancedDashboardScroll.Visibility = if ($IsSimple) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $CurrentLanguage=if($script:CurrentUiLanguage){[string]$script:CurrentUiLanguage}else{try{[string](Get-RustInstanceCatalog -ServerRoot $ServerRoot).language}catch{'fr-FR'}}
    $English=$CurrentLanguage-eq'en-US'
    $Ui.SidebarModeLabel.Text = if ($IsSimple) { if($English){'SIMPLE MODE'}else{'MODE SIMPLE'} } else { if($English){'SERVER MANAGEMENT'}else{'GESTION DU SERVEUR'} }
    $Ui.InterfaceModeButton.Content = if ($IsSimple) { if($English){'ADVANCED MODE'}else{'MODE AVANCÉ'} } else { if($English){'SIMPLE MODE'}else{'MODE SIMPLE'} }
    $Ui.InterfaceModeButton.ToolTip = if ($IsSimple) { if($English){'Show all technical tools'}else{'Afficher tous les outils techniques'} } else { if($English){'Return to essential actions'}else{'Revenir aux actions essentielles'} }
    # Les deux modes conservent la marque de l'application dans l'en-tête.
    # Une reconstruction du menu avancé ne doit jamais masquer ces éléments.
    $Ui.HeaderLogoImage.Visibility = [Windows.Visibility]::Visible
    $Ui.HeaderLogoImage.Opacity = 1
    $Ui.HeaderTitleText.Visibility = [Windows.Visibility]::Visible
    $Ui.HeaderTitleText.Opacity = 1
    $Ui.HeaderTitleText.Foreground = $BrushConverter.ConvertFromString('#F0E8DE')

    if ($IsSimple) {
        $Ui.SimpleNavigation.SelectedIndex = 0
        $Ui.MainTabs.SelectedIndex = 0
    }
    elseif ($Ui.MainTabs.SelectedIndex -lt 0) {
        Select-AdvancedNav -Tab 0
        $Ui.MainTabs.SelectedIndex = 0
    }
    # Hors mode avance la barre se masque ; en mode avance elle resynchronise
    # la section et la surbrillance sur l'onglet deja ouvert.
    Update-SubNav
    if (-not $NoSave) { Set-RustControlCenterUiMode -ServerRoot $ServerRoot -Mode $Mode }
}

function Open-SimpleDestination([int]$TabIndex) {
    $Ui.MainTabs.SelectedIndex = $TabIndex
    $MatchIndex = -1
    for ($Index = 0; $Index -lt $Ui.SimpleNavigation.Items.Count; $Index++) {
        if ([int]$Ui.SimpleNavigation.Items[$Index].Tag -eq $TabIndex) { $MatchIndex = $Index; break }
    }
    if ($MatchIndex -ge 0) { $Ui.SimpleNavigation.SelectedIndex = $MatchIndex }
    if ($TabIndex -eq 9 -and -not $script:NetworkDiagnosticRequested) {
        $script:NetworkDiagnosticRequested = $true
        Refresh-NetworkDiagnostics
    }
}

$script:SuppressDialogs = $true

function Show-ErrorDialog([string]$Message) {
    # Aucune boite modale tant que l'application n'est pas rendue, et jamais en
    # mode capture : une erreur survenue pendant l'initialisation ouvrait un
    # dialogue que personne ne pouvait fermer, laissant l'application figee
    # indefiniment. L'erreur reste visible dans la barre d'activite.
    if ($script:SuppressDialogs -or $CapturePath) {
        Set-Activity ('Erreur : ' + $Message)
        return
    }
    [Windows.MessageBox]::Show($Window, $Message, 'Operation impossible', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Error) | Out-Null
}

function Confirm-Action([string]$Message, [string]$Title = 'Confirmer') {
    return [Windows.MessageBox]::Show($Window, $Message, $Title, [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning) -eq [Windows.MessageBoxResult]::Yes
}

function Invoke-UiAction([scriptblock]$Action) {
    try { & $Action }
    catch {
        Set-Activity ('Erreur : ' + $_.Exception.Message)
        Show-ErrorDialog $_.Exception.Message
    }
}

function Invoke-BusyAction([scriptblock]$Action) {
    # Reserve aux petites operations locales et aux confirmations de securite.
    $Previous = $Window.Cursor
    $Window.Cursor = [Windows.Input.Cursors]::Wait
    try { & $Action }
    finally { $Window.Cursor = $Previous }
}

# Une seule operation serveur a la fois. Les appels RCON s'executent dans un
# runspace distinct ; le Dispatcher WPF reste libre pour peindre, defiler et
# permettre a l'utilisateur de changer de page.
$script:ServerOperationQueue = New-Object System.Collections.Queue
$script:ActiveServerOperation = $null
$script:NextServerOperationAt = [datetime]::MinValue

function Start-NextServerOperation {
    if ($script:ActiveServerOperation -or $script:ServerOperationQueue.Count -eq 0) { return }
    if ((Get-Date) -lt $script:NextServerOperationAt) { return }

    $Job = $script:ServerOperationQueue.Dequeue()
    $PowerShell = [PowerShell]::Create()
    $Worker = {
        param($CommonPath,$ServerRoot,$Operation,$Command,$TimeoutMs)
        $ErrorActionPreference = 'Stop'
        . $CommonPath
        switch ($Operation) {
            'command' {
                return [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command $Command -TimeoutMs $TimeoutMs)
            }
            'players' {
                return ([pscustomobject]@{ items = @(Get-RustRpgPlayers -ServerRoot $ServerRoot) } | ConvertTo-Json -Depth 8 -Compress)
            }
            'bans' {
                return ([pscustomobject]@{ items = @(Get-RustRpgBans -ServerRoot $ServerRoot) } | ConvertTo-Json -Depth 8 -Compress)
            }
            'stats' {
                $Stats = Get-RustRpgStats -ServerRoot $ServerRoot
                if ($null -eq $Stats) { return '' }
                return ($Stats | ConvertTo-Json -Depth 12 -Compress)
            }
            'activity' {
                return (Get-RustRpgActivity -ServerRoot $ServerRoot | ConvertTo-Json -Depth 8 -Compress)
            }
            'network' {
                return ([pscustomobject]@{ items = @(Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot -FriendCommand $Command) } | ConvertTo-Json -Depth 10 -Compress)
            }
            'dashboard' {
                $State = Get-RustRpgServerState -ServerRoot $ServerRoot
                if (-not $State.Running) {
                    return ([pscustomobject]@{ running=$false; info=$null; players=@() } | ConvertTo-Json -Depth 10 -Compress)
                }
                $Info = Get-RustRpgServerInfo -ServerRoot $ServerRoot -RconPort ([int]$State.RconPort) -TimeoutMs $TimeoutMs
                $Players = @(Get-RustRpgPlayers -ServerRoot $ServerRoot -RconPort ([int]$State.RconPort) -TimeoutMs $TimeoutMs)
                return ([pscustomobject]@{ running=$true; info=$Info; players=$Players } | ConvertTo-Json -Depth 10 -Compress)
            }
            default { throw "Operation serveur inconnue : $Operation" }
        }
    }
    $null = $PowerShell.AddScript($Worker).AddArgument((Join-Path $PSScriptRoot 'RustRPG-Common.ps1')).AddArgument($ServerRoot).AddArgument($Job.Operation).AddArgument($Job.Command).AddArgument($Job.TimeoutMs)
    $Job | Add-Member -NotePropertyName PowerShell -NotePropertyValue $PowerShell
    $Job | Add-Member -NotePropertyName AsyncResult -NotePropertyValue ($PowerShell.BeginInvoke())
    $script:ActiveServerOperation = $Job
    if (-not $Job.Silent) {
        $Window.Cursor = [Windows.Input.Cursors]::AppStarting
        Set-Activity ("En cours : " + $Job.Label)
    }
}

function Queue-ServerOperation {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('command','players','bans','stats','activity','network','dashboard')][string]$Operation,
        [string]$Command = '',
        [string]$Label = 'operation serveur',
        [int]$TimeoutMs = 10000,
        [scriptblock]$OnSuccess = {},
        [scriptblock]$OnError = {},
        [switch]$Silent
    )

    $script:ServerOperationQueue.Enqueue([pscustomobject]@{
        Operation = $Operation
        Command = $Command
        Label = $Label
        TimeoutMs = $TimeoutMs
        OnSuccess = $OnSuccess.GetNewClosure()
        OnError = $OnError.GetNewClosure()
        Silent = [bool]$Silent
    })
    if (-not $Silent) { Set-Activity ("Ajoute a la file : " + $Label) }
    Start-NextServerOperation
}

function Complete-ServerOperation {
    $Job = $script:ActiveServerOperation
    if (-not $Job -or -not $Job.AsyncResult.IsCompleted) { return }

    try {
        $Output = @($Job.PowerShell.EndInvoke($Job.AsyncResult)) -join [Environment]::NewLine
        if ($Job.PowerShell.Streams.Error.Count -gt 0) {
            throw [string]$Job.PowerShell.Streams.Error[0]
        }
        & $Job.OnSuccess $Output
    }
    catch {
        $Message = $_.Exception.Message
        if (-not $Job.Silent) { Set-Activity ("Erreur : " + $Message) }
        if ($Job.OnError.ToString().Trim()) { & $Job.OnError $Message }
        else { Show-ErrorDialog $Message }
    }
    finally {
        try { $Job.PowerShell.Dispose() } catch {}
        $script:ActiveServerOperation = $null
        $script:NextServerOperationAt = (Get-Date).AddMilliseconds(300)
        if (-not $Job.Silent) { $Window.Cursor = [Windows.Input.Cursors]::Arrow }
        Start-NextServerOperation
    }
}

function Confirm-Disruption([string]$ActionLabel) {
    <#
        Regle critique n°8 : un reload ou un arret peut couper une partie.
        On interroge le serveur avant, et on ne passe en force qu'apres un
        accord explicite. Un etat inconnu est traite comme un risque.
    #>
    if (-not (Get-RustRpgServerState).Running) { return $true }

    Set-Activity 'Verification des joueurs et des parties en cours...'
    $Activity = Invoke-BusyAction { Get-RustRpgActivity -ServerRoot $ServerRoot }

    if (-not $Activity.Known) {
        return Confirm-Action (
            "Impossible de verifier l'etat des parties.`n$($Activity.Error)`n`n" +
            "$ActionLabel malgre tout ?") 'Etat des parties inconnu'
    }

    if ($Activity.PlayerCount -eq 0 -and $Activity.ActiveModes.Count -eq 0) {
        Set-Activity 'Aucun joueur ni partie en cours.'
        return $true
    }

    $Details = @()
    if ($Activity.PlayerCount -gt 0) {
        $Names = if ($Activity.Players.Count -gt 0) { ' : ' + ($Activity.Players -join ', ') } else { '' }
        $Details += "$($Activity.PlayerCount) joueur(s) connecte(s)$Names"
    }
    if ($Activity.ActiveModes.Count -gt 0) {
        $Details += "Partie(s) en cours : $($Activity.ActiveModes -join ', ')"
    }

    return Confirm-Action (
        "$ActionLabel risque d'interrompre une partie.`n`n" + ($Details -join "`n") +
        "`n`nContinuer quand meme ?") 'Partie en cours'
}

function Invoke-AfterDisruptionCheck {
    param(
        [Parameter(Mandatory = $true)][string]$ActionLabel,
        [Parameter(Mandatory = $true)][scriptblock]$Continuation
    )

    $Next = $Continuation.GetNewClosure()
    if (-not (Get-RustRpgServerState).Running) { & $Next; return }

    Queue-ServerOperation -Operation activity -Label 'verification des joueurs et parties' -OnSuccess {
        param($Json)
        $Activity = $null
        try { $Activity = $Json | ConvertFrom-Json } catch {}

        if (-not $Activity -or -not $Activity.Known) {
            $ErrorText = if ($Activity) { [string]$Activity.Error } else { 'Reponse de verification invalide.' }
            if (Confirm-Action "Impossible de verifier l'etat des parties.`n$ErrorText`n`n$ActionLabel malgre tout ?" 'Etat des parties inconnu') { & $Next }
            else { Set-Activity 'Action annulee.' }
            return
        }

        $Modes = @($Activity.ActiveModes)
        $Players = @($Activity.Players)
        if ([int]$Activity.PlayerCount -eq 0 -and $Modes.Count -eq 0) { & $Next; return }

        $Details = @()
        if ([int]$Activity.PlayerCount -gt 0) {
            $Names = if ($Players.Count -gt 0) { ' : ' + ($Players -join ', ') } else { '' }
            $Details += "$($Activity.PlayerCount) joueur(s) connecte(s)$Names"
        }
        if ($Modes.Count -gt 0) { $Details += 'Partie(s) en cours : ' + ($Modes -join ', ') }

        if (Confirm-Action ("$ActionLabel risque d'interrompre une partie.`n`n" + ($Details -join "`n") + "`n`nContinuer quand meme ?") 'Partie en cours') { & $Next }
        else { Set-Activity 'Action annulee.' }
    } -OnError {
        param($Message)
        if (Confirm-Action "Impossible de verifier l'etat des parties.`n$Message`n`n$ActionLabel malgre tout ?" 'Etat des parties inconnu') { & $Next }
        else { Set-Activity 'Action annulee.' }
    }
}

$script:FriendCommandCache = $null
$script:FriendCommandCheckedAt = [datetime]::MinValue
$script:PublicIpTask = $null
$script:PublicIpClient = $null
# Joignabilite vue depuis Internet, via le repertoire public de Steam.
$script:ReachTask = $null
$script:ReachClient = $null
$script:ReachIp = ''
$script:ReachPort = 0
$script:ReachState = ''
$script:ReachCheckedAt = [datetime]::MinValue
$script:ReachProcessId = 0
$script:ReachProcessStart = [datetime]::MinValue
$script:VisualConfigRows = @()
$script:VisualConfigObject = $null
$script:VisualConfigLines = @()
$script:VisualConfigLineEnding = "`r`n"
$script:VisualConfigKind = ''
$script:ConfigTabChangeGuard = $false
$script:NetworkDiagnosticsCache = @()
$script:NetworkDiagnosticRequested = $false
$script:DetectedPlugins = @()
$script:PluginCatalog = @()
$script:PluginSdkControlMap = @{}
$script:ModeCapabilities = @()
$ConnectionFilePath = Join-Path $ServerRoot 'CONNEXION-AMIS.txt'

function Get-DisplayedPlugins {
    if ($ForceVanillaUi) { return @() }
    return @(Get-RustPluginCatalog -ServerRoot $ServerRoot)
}

function Get-DisplayedEnvironment {
    if ($ForceVanillaUi) {
        return [pscustomobject]@{ Id='vanilla'; Label='VANILLA'; Installed=$false; Version='' }
    }
    return Get-RustModEnvironment -ServerRoot $ServerRoot
}

function Get-PublicServerPort {
    try {
        $PublicInstance = @(Get-RustServerInstances -ServerRoot $ServerRoot | Where-Object isPublic | Select-Object -First 1)
        if ($PublicInstance.Count) { return [int]$PublicInstance[0].serverPort }
    } catch { }
    return 28115
}

function Read-FriendCommandFromFile {
    # Lecture disque uniquement : jamais de reseau, donc jamais de gel de l'UI.
    if (-not (Test-Path -LiteralPath $ConnectionFilePath)) { return $null }
    $Text = Get-Content -LiteralPath $ConnectionFilePath -Raw
    $Match = [regex]::Match($Text, 'client\.connect\s+(?!127\.0\.0\.1)(\S+)')
    if ($Match.Success) { return 'client.connect ' + $Match.Groups[1].Value }
    return $null
}

function Save-FriendCommandToFile([string]$Command) {
    if (-not (Test-Path -LiteralPath $ConnectionFilePath)) { return }
    $Text = Get-Content -LiteralPath $ConnectionFilePath -Raw
    $Pattern = New-Object Text.RegularExpressions.Regex('^client\.connect\s+(?!127\.0\.0\.1).+$',[Text.RegularExpressions.RegexOptions]::Multiline)
    $Updated = $Pattern.Replace($Text,$Command,1)
    if ($Updated -ne $Text) {
        Set-Content -LiteralPath $ConnectionFilePath -Value $Updated -Encoding UTF8
    }
}

function Start-PublicIpLookup {
    <#
        Lance la resolution de l'IP publique sans bloquer. L'ancienne version
        appelait Invoke-RestMethod depuis le tick du timer : l'UI gelait jusqu'a
        5 secondes a chaque expiration du cache.
    #>
    if ($script:PublicIpTask -and -not $script:PublicIpTask.IsCompleted) { return }
    if (-not $script:PublicIpClient) {
        $script:PublicIpClient = New-Object Net.Http.HttpClient
        $script:PublicIpClient.Timeout = [TimeSpan]::FromSeconds(8)
    }
    $script:PublicIpTask = $script:PublicIpClient.GetStringAsync('https://api.ipify.org')
}

function Start-ReachabilityCheck([string]$PublicIp, [int]$QueryPort) {
    <#
        Demande a Steam, depuis Internet, s'il voit notre serveur. C'est le seul
        controle de la box possible sans ses identifiants : si Steam joint le
        port de requetes, la redirection fonctionne. Asynchrone, comme l'IP
        publique : la version du diagnostic attend la reponse et gelerait l'UI
        si on l'appelait depuis le minuteur.
    #>
    if ($script:ReachTask -and -not $script:ReachTask.IsCompleted) { return }
    if (-not $script:ReachClient) {
        $script:ReachClient = New-Object Net.Http.HttpClient
        $script:ReachClient.Timeout = [TimeSpan]::FromSeconds(10)
    }
    $script:ReachIp = $PublicIp
    $script:ReachPort = $QueryPort
    $Address = [Uri]::EscapeDataString("${PublicIp}:$QueryPort")
    $script:ReachTask = $script:ReachClient.GetStringAsync("https://api.steampowered.com/ISteamApps/GetServersAtAddress/v1/?addr=$Address&format=json")
}

function Complete-ReachabilityCheck {
    if (-not $script:ReachTask -or -not $script:ReachTask.IsCompleted) { return }
    $Task = $script:ReachTask
    $script:ReachTask = $null
    $script:ReachCheckedAt = Get-Date
    # Une panne de Steam ne prouve pas que le port est ferme : etat distinct.
    if ($Task.IsFaulted -or $Task.IsCanceled) { $script:ReachState = 'unknown'; return }
    try {
        $Document = ([string]$Task.Result) | ConvertFrom-Json
        if (-not [bool]$Document.response.success) { $script:ReachState = 'unknown'; return }
        $Record = @(Find-RustRpgSteamServerRecord -Document $Document -PublicIp $script:ReachIp -QueryPort $script:ReachPort) | Select-Object -First 1
        $script:ReachState = if ($Record) { 'ok' } else { 'missing' }
    }
    catch { $script:ReachState = 'unknown' }
}

function Set-ReachLine([string]$Text, [string]$Color) {
    $Ui.SideReachText.Text = $Text
    $Ui.SideReachText.Foreground = $BrushConverter.ConvertFromString($Color)
    $Ui.SideReachText.Visibility = [Windows.Visibility]::Visible
}

function Update-BoxCorrelation($Selected, $SelectedProcess) {
    # Met la carte en regard de la box : la regle qu'elle doit contenir, ecrite
    # comme dans le tableau NAT de la Livebox, puis la preuve qu'elle marche.
    try {
        if (-not $Selected -or -not [bool]$Selected.isPublic) {
            $Ui.SideBoxRuleText.Visibility = [Windows.Visibility]::Collapsed
            $Ui.SideReachText.Visibility = [Windows.Visibility]::Collapsed
            return
        }
        $GamePort = [int]$Selected.serverPort
        $QueryPort = [int]$Selected.queryPort
        $Ui.SideBoxRuleText.Text = "Box : UDP $GamePort + UDP $QueryPort → $($env:COMPUTERNAME)"
        $Ui.SideBoxRuleText.Visibility = [Windows.Visibility]::Visible

        # Les captures de documentation ne doivent ni appeler Internet ni
        # divulguer l'adresse reelle.
        if ($CapturePath) { Set-ReachLine 'Vérification de la box à l''exécution.' '#8E8478'; return }

        Complete-ReachabilityCheck

        if (-not $SelectedProcess) {
            $script:ReachState = ''
            $script:ReachCheckedAt = [datetime]::MinValue
            Set-ReachLine 'Serveur arrêté : démarre-le pour tester la box.' '#8E8478'
            return
        }

        $PublicIp = ''
        if ($script:FriendCommandCache -match 'client\.connect\s+\[?([0-9A-Fa-f\.:]+?)\]?:\d+$') { $PublicIp = $Matches[1] }
        if (-not $PublicIp) { Set-ReachLine 'Adresse publique inconnue : clique sur ACTUALISER.' '#E2A33D'; return }

        # Nouvelle IP, nouveau port ou redemarrage : l'ancien verdict ne vaut plus.
        $ProcessId = [int]$SelectedProcess.ProcessId
        if ($ProcessId -ne $script:ReachProcessId) {
            $script:ReachProcessId = $ProcessId
            $script:ReachProcessStart = Get-Date
            try { $script:ReachProcessStart = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime } catch { }
            $script:ReachState = ''
            $script:ReachCheckedAt = [datetime]::MinValue
        }
        if ($script:ReachIp -ne $PublicIp -or $script:ReachPort -ne $QueryPort) {
            $script:ReachState = ''
            $script:ReachCheckedAt = [datetime]::MinValue
        }

        # Une fois joignable on revérifie toutes les 5 min, sinon chaque minute :
        # c'est la que l'utilisateur est en train de regler sa box.
        $Interval = if ($script:ReachState -eq 'ok') { 300 } else { 60 }
        if (((Get-Date) - $script:ReachCheckedAt).TotalSeconds -ge $Interval) { Start-ReachabilityCheck $PublicIp $QueryPort }

        $CheckedAt = if ($script:ReachCheckedAt -gt [datetime]::MinValue) { ' · ' + $script:ReachCheckedAt.ToString('HH:mm') } else { '' }
        $UptimeMinutes = ((Get-Date) - $script:ReachProcessStart).TotalMinutes
        switch ($script:ReachState) {
            'ok' { Set-ReachLine ("✓ Joignable depuis Internet$CheckedAt") '#72D79B' }
            'missing' {
                # Steam met une a deux minutes a enregistrer un serveur qui demarre.
                if ($UptimeMinutes -lt 4) { Set-ReachLine 'Démarrage : Steam enregistre le serveur...' '#E2A33D' }
                else { Set-ReachLine ("✗ Pas vu depuis Internet$CheckedAt : vérifie la règle de la box.") '#E76A4C' }
            }
            'unknown' { Set-ReachLine ("Steam ne répond pas$CheckedAt : rien de conclu sur la box.") '#E2A33D' }
            default { Set-ReachLine 'Vérification de la box...' '#8E8478' }
        }
    }
    catch {
        # Une carte d'information ne doit jamais faire tomber le minuteur.
        $Ui.SideReachText.Visibility = [Windows.Visibility]::Collapsed
    }
}

function Complete-PublicIpLookup {
    # Appelee a chaque tick : ne fait rien tant que la tache n'est pas terminee.
    if (-not $script:PublicIpTask -or -not $script:PublicIpTask.IsCompleted) { return $false }
    $Task = $script:PublicIpTask
    $script:PublicIpTask = $null
    if ($Task.IsFaulted -or $Task.IsCanceled) { return $false }

    $PublicIp = ([string]$Task.Result).Trim()
    $ParsedIp = $null
    if (-not [Net.IPAddress]::TryParse($PublicIp,[ref]$ParsedIp)) { return $false }

    $FriendPort = Get-PublicServerPort
    $Command = if ($ParsedIp.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetworkV6) { "client.connect [$PublicIp]:$FriendPort" } else { "client.connect ${PublicIp}:$FriendPort" }
    try {
        $AddressState = Update-RustNetworkAddressState -ServerRoot $ServerRoot -PublicIp $PublicIp
        if (-not $CapturePath -and ([bool]$AddressState.lanChanged -or [bool]$AddressState.publicChanged)) {
            $ChangeMessage = if ([bool]$AddressState.lanChanged) { "L’IP locale a changé : $($AddressState.previousLanIp) → $($AddressState.lastLanIp). Vérifie la redirection du routeur." } else { "L’IP publique a changé : $($AddressState.previousPublicIp) → $($AddressState.lastPublicIp). La commande amis a été actualisée." }
            Set-Activity $ChangeMessage
            Initialize-OperationNotifications
            if ($script:OperationNotifyIcon) { $script:OperationNotifyIcon.BalloonTipTitle='Adresse réseau modifiée';$script:OperationNotifyIcon.BalloonTipText=$ChangeMessage;$script:OperationNotifyIcon.BalloonTipIcon=[Windows.Forms.ToolTipIcon]::Warning;$script:OperationNotifyIcon.ShowBalloonTip(9000) }
        }
        $PublicInstance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
        if ($PublicInstance.Count) {
            $Document = Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $PublicInstance[0] -AddressState $AddressState
            $Command = [string]$Document.Endpoint.Command
        }
    }
    catch { try { Save-FriendCommandToFile $Command } catch {} }
    $script:FriendCommandCache = $Command
    $script:FriendCommandCheckedAt = Get-Date
    return $true
}

function Get-FriendCommand([switch]$ForceRefresh) {
    # Retourne immediatement la meilleure valeur connue et declenche au besoin
    # une resolution en arriere-plan dont le resultat arrivera a un tick suivant.
    if (-not $script:FriendCommandCache) {
        $script:FriendCommandCache = Read-FriendCommandFromFile
    }
    $CacheAge = (Get-Date) - $script:FriendCommandCheckedAt
    if ($ForceRefresh -or $CacheAge.TotalMinutes -ge 5) {
        Start-PublicIpLookup
    }
    $FriendPort = Get-PublicServerPort
    if (-not $script:FriendCommandCache) { return "client.connect ADRESSE_IP:$FriendPort" }
    $script:FriendCommandCache = [regex]::Replace($script:FriendCommandCache,':\d+$',":$FriendPort")
    return $script:FriendCommandCache
}

function Get-SelectedText($Combo) {
    if ($null -eq $Combo.SelectedItem) { return '' }
    if ($Combo.SelectedItem.PSObject.Properties.Name -contains 'Identity') { return [string]$Combo.SelectedItem.Identity }
    if ($Combo.SelectedItem.PSObject.Properties.Name -contains 'Code') { return [string]$Combo.SelectedItem.Code }
    if ($null -ne $Combo.SelectedValue -and $Combo.SelectedValue -is [string]) { return [string]$Combo.SelectedValue }
    return [string]$Combo.SelectedItem
}

$script:InstanceRefreshGuard = $false

function Get-SelectedServerInstance {
    $Row = $Ui.InstanceGrid.SelectedItem
    if ($Row -and $Row.PSObject.Properties.Name -contains 'Id') {
        return Get-RustServerInstance -ServerRoot $ServerRoot -Id ([string]$Row.Id)
    }
    return Get-RustServerInstance -ServerRoot $ServerRoot
}

function Refresh-InstanceSelectors([string]$SelectedIdentity = '') {
    $Items = @(Get-RustServerInstances -ServerRoot $ServerRoot | ForEach-Object {
        [pscustomobject]@{ Id=[string]$_.id; DisplayName=[string]$_.displayName; Identity=[string]$_.identity }
    })
    foreach ($Combo in @($Ui.MapIdentityCombo,$Ui.WipeIdentityCombo,$Ui.ScheduleIdentityCombo)) {
        $Previous = if ($SelectedIdentity) { $SelectedIdentity } else { Get-SelectedText $Combo }
        $Combo.DisplayMemberPath = 'DisplayName'
        $Combo.SelectedValuePath = 'Identity'
        $Combo.ItemsSource = $Items
        if ($Previous -and @($Items | Where-Object Identity -eq $Previous).Count) { $Combo.SelectedValue = $Previous }
        elseif ($Items.Count) { $Combo.SelectedIndex = 0 }
    }
    $PreviousSupervisionId = [string]$Ui.SupervisionInstanceCombo.SelectedValue
    $Ui.SupervisionInstanceCombo.DisplayMemberPath = 'DisplayName'
    $Ui.SupervisionInstanceCombo.SelectedValuePath = 'Id'
    $Ui.SupervisionInstanceCombo.ItemsSource = $Items
    if($PreviousSupervisionId -and @($Items|Where-Object Id -eq $PreviousSupervisionId).Count){$Ui.SupervisionInstanceCombo.SelectedValue=$PreviousSupervisionId}
    elseif($Items.Count){$Selected=Get-RustServerInstance -ServerRoot $ServerRoot;$Ui.SupervisionInstanceCombo.SelectedValue=[string]$Selected.id}
}

function Load-InstanceEditor {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { return }
    $Ui.InstanceNameBox.Text = [string]$Instance.displayName
    $Ui.InstanceIdentityBox.Text = [string]$Instance.identity
    $Ui.InstanceIdentityBox.IsReadOnly = $true
    $Ui.InstanceGamePortBox.Text = [string]$Instance.serverPort
    $Ui.InstanceRconPortBox.Text = [string]$Instance.rconPort
    $Ui.InstanceQueryPortBox.Text = [string]$Instance.queryPort
    $Ui.InstanceAppPortBox.Text = [string]$Instance.appPort
    $Ui.InstanceEnabledCheck.IsChecked = [bool]$Instance.enabled
    $Ui.InstancePublicCheck.IsChecked = [bool]$Instance.isPublic
    $Ui.InstanceGamePortText.Text = "UDP $($Instance.serverPort)"
    $Ui.InstanceQueryPortText.Text = "UDP $($Instance.queryPort)"
    $Ui.InstanceRconPortText.Text = "127.0.0.1:$($Instance.rconPort)"
    $Isolation = Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
    $Ui.InstanceIsolationCombo.SelectedValue = [string]$Isolation.Mode
    $Ui.InstanceIsolationStatusText.Text = [string]$Isolation.Label
    $Ui.InstanceIsolationPathText.Text = [string]$Isolation.RuntimeRoot
    $Ui.InstanceIsolationStatusText.Foreground = $BrushConverter.ConvertFromString($(if($Isolation.Ready){'#72D79B'}elseif($Isolation.Mode -eq 'full'){'#E76A4C'}else{'#EFA45D'}))
    $Ui.InstanceIsolationDetailText.Text = if($Isolation.Mode -eq 'full' -and $Isolation.Ready){"Runtime indépendant prêt ($($Isolation.DiskGb) Go). Les fichiers Carbon et les plugins de cette instance ne sont pas partagés."}elseif($Isolation.Mode -eq 'full'){"Le profil est isolé, mais son logiciel serveur n'est pas encore installé."}else{"Le logiciel est partagé. Les mondes vanilla restent séparés par server.identity ; Carbon reste commun à toutes les instances partagées."}
    $Ui.InstallIsolatedRuntimeButton.IsEnabled = [string]$Isolation.Mode -eq 'full' -and -not [bool]$Isolation.Ready
    Load-ServerSettings
}

function Refresh-Instances {
    $script:InstanceRefreshGuard = $true
    try {
        $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
        $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
        $Rows = foreach ($Instance in @($Catalog.instances)) {
            $Process = @($Processes | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
            [pscustomobject]@{
                Id      = [string]$Instance.id
                Etat    = if ($Process) { 'ACTIF' } else { 'ARRÊTÉ' }
                Nom     = [string]$Instance.displayName
                Usage   = if ([bool]$Instance.isPublic) { 'PUBLIC' } else { 'LOCAL' }
                Port    = [int]$Instance.serverPort
                Carte   = if ([string]$Instance.levelUrl) { 'CUSTOM' } else { "SEED $($Instance.seed)" }
                Identity= [string]$Instance.identity
                Pid     = if ($Process) { [int]$Process.ProcessId } else { 0 }
                HeaderDisplay = ('{0} (127.0.0.1:{1})' -f [string]$Instance.displayName,[int]$Instance.serverPort)
            }
        }
        $Ui.InstanceGrid.ItemsSource = @($Rows)
        $SelectedRow = @($Rows | Where-Object Id -eq ([string]$Catalog.selectedId)) | Select-Object -First 1
        if ($SelectedRow) { $Ui.InstanceGrid.SelectedItem = $SelectedRow }
        $Ui.HeaderInstanceCombo.DisplayMemberPath = 'HeaderDisplay'
        $Ui.HeaderInstanceCombo.SelectedValuePath = 'Id'
        $Ui.HeaderInstanceCombo.ItemsSource = @($Rows)
        if ($SelectedRow) { $Ui.HeaderInstanceCombo.SelectedValue = [string]$SelectedRow.Id }
        $Ui.AllowMultiInstanceCheck.IsChecked = [bool]$Catalog.allowMultiInstance

        $Os = Get-CimInstance Win32_OperatingSystem
        $TotalRamGb = [math]::Round([double]$Os.TotalVisibleMemorySize / 1MB,1)
        $FreeRamGb = [math]::Round([double]$Os.FreePhysicalMemory / 1MB,1)
        $Enabled = @($Catalog.instances | Where-Object enabled)
        $Estimate = [math]::Round((($Enabled | Measure-Object -Property memoryEstimateGb -Sum).Sum),1)
        $Recommended = [math]::Max(1,[math]::Floor(($TotalRamGb - 4) / 6))
        $Ui.InstanceResourceText.Text = "$($Enabled.Count) instance(s) activée(s) ≈ $Estimate Go estimés. RAM PC : $TotalRamGb Go, libre maintenant : $FreeRamGb Go. Maximum prudent estimé : $Recommended instance(s)."
        Refresh-InstanceSelectors
        Load-InstanceEditor
    }
    finally { $script:InstanceRefreshGuard = $false }
}

function Select-InstanceFromGrid {
    if ($script:InstanceRefreshGuard) { return }
    $Row = $Ui.InstanceGrid.SelectedItem
    if (-not $Row) { return }
    $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id ([string]$Row.Id)
    $script:InstanceRefreshGuard = $true
    try { $Ui.HeaderInstanceCombo.SelectedValue = [string]$Row.Id }
    finally { $script:InstanceRefreshGuard = $false }
    Load-InstanceEditor
    Update-RuntimeDisplay
}

function Select-InstanceFromHeader {
    if ($script:InstanceRefreshGuard -or -not $Ui.HeaderInstanceCombo.SelectedValue) { return }
    $Id = [string]$Ui.HeaderInstanceCombo.SelectedValue
    $Row = @($Ui.InstanceGrid.ItemsSource | Where-Object Id -eq $Id) | Select-Object -First 1
    if (-not $Row) { return }
    $Ui.InstanceGrid.SelectedItem = $Row
    $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id $Id
    Load-InstanceEditor
    Update-RuntimeDisplay
}

function ConvertTo-InstancePort([string]$Text,[string]$Label) {
    $Value = 0
    if (-not [int]::TryParse($Text,[ref]$Value) -or $Value -lt 1025 -or $Value -gt 65535) {
        throw "$Label : indique un port entre 1025 et 65535."
    }
    return $Value
}

function Save-SelectedInstance {
    $Row = $Ui.InstanceGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une instance.' }
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object id -eq ([string]$Row.Id)) | Select-Object -First 1
    if (-not $Instance) { throw 'Instance introuvable.' }
    $Running = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity))
    $NewPorts = @(
        (ConvertTo-InstancePort $Ui.InstanceGamePortBox.Text 'Port jeu'),
        (ConvertTo-InstancePort $Ui.InstanceRconPortBox.Text 'Port RCON'),
        (ConvertTo-InstancePort $Ui.InstanceQueryPortBox.Text 'Port query'),
        (ConvertTo-InstancePort $Ui.InstanceAppPortBox.Text 'Port Rust+')
    )
    if (@($NewPorts | Select-Object -Unique).Count -ne 4) { throw 'Les quatre ports de cette instance doivent être différents.' }
    if ($Running.Count -and ($NewPorts[0] -ne [int]$Instance.serverPort -or $NewPorts[1] -ne [int]$Instance.rconPort -or $NewPorts[2] -ne [int]$Instance.queryPort -or $NewPorts[3] -ne [int]$Instance.appPort)) {
        throw 'Arrête cette instance avant de modifier ses ports.'
    }
    if (-not $Ui.InstanceNameBox.Text.Trim()) { throw 'Le nom affiché est obligatoire.' }
    $Instance.displayName = $Ui.InstanceNameBox.Text.Trim()
    $Instance.serverPort = $NewPorts[0]
    $Instance.rconPort = $NewPorts[1]
    $Instance.queryPort = $NewPorts[2]
    $Instance.appPort = $NewPorts[3]
    $Instance.enabled = [bool]$Ui.InstanceEnabledCheck.IsChecked
    $Instance.isPublic = [bool]$Ui.InstancePublicCheck.IsChecked
    $null = Save-RustInstanceCatalog -ServerRoot $ServerRoot -Catalog $Catalog
    $null = Initialize-RustInstanceStorage -ServerRoot $ServerRoot -Instance $Instance
    Refresh-Instances
    Update-NetworkHeader
    Set-Activity "Instance '$($Instance.displayName)' enregistrée."
}

function Create-ServerInstance([switch]$Duplicate) {
    $SourceId = ''
    if ($Duplicate) {
        $Selected = Get-SelectedServerInstance
        if (-not $Selected) { throw 'Sélectionne une instance à dupliquer.' }
        $SourceId = [string]$Selected.id
    }
    $Instance = New-RustServerInstance -ServerRoot $ServerRoot -CopyFromId $SourceId
    Refresh-Instances
    Set-Activity "Instance '$($Instance.displayName)' créée. Les données de monde ne sont pas copiées."
}

function Apply-SelectedInstanceIsolation {
    $Instance=Get-SelectedServerInstance;if(-not$Instance){throw 'Sélectionne une instance.'}
    $Mode=[string]$Ui.InstanceIsolationCombo.SelectedValue
    if($Mode-eq'full' -and [string]$Instance.isolationMode-ne'full'){
        if(-not(Confirm-Action "Passer '$($Instance.displayName)' en runtime isolé ?`n`nLe profil sera configuré, mais le téléchargement séparé de Rust (environ 15 à 20 Go) ne commencera qu'avec le bouton Installer. Les mondes actuels restent en place." 'Isolation complète')){return}
    }
    $Status=Set-RustInstanceIsolation -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -Mode $Mode
    Load-InstanceEditor;Set-Activity "Isolation enregistrée : $($Status.Label)."
}

function Start-SelectedIsolatedRuntimeInstall {
    $Instance=Get-SelectedServerInstance;if(-not$Instance){throw 'Sélectionne une instance.'}
    if([string]$Instance.isolationMode-ne'full'){throw "Choisis d'abord Runtime complet isolé puis applique le mode."}
    $Status=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
    if($Status.Ready){throw 'Le runtime isolé est déjà prêt.'}
    if(-not(Confirm-Action "Télécharger et vérifier un deuxième Rust Dedicated pour '$($Instance.displayName)' ?`n`nPrévois environ 15 à 20 Go et plusieurs minutes. Rust ne sera pas démarré." 'Installer le runtime isolé')){return}
    $Worker=Join-Path $PSScriptRoot 'RustRPG-IsolationWorker.ps1';$Log=Get-OperationLogPath 'isolation';$ErrorLog=$Log+'.err'
    $Tracked=New-RustTrackedOperation -ServerRoot $ServerRoot -Type IsolationInstall -Title ('Runtime isolé de '+[string]$Instance.displayName) -ServerId ([string]$Instance.id) -Stage 'PRÉPARATION' -Detail 'Préparation de SteamCMD.' -RetryAction 'isolation-install' -CanCancel $true -LogPath $Log -ErrorLogPath $ErrorLog -Metadata ([pscustomobject]@{instanceId=[string]$Instance.id;includeCarbon=[bool]$Ui.InstanceIsolationCarbonCheck.IsChecked})
    $PsExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$Args=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$Worker+'"'),'-ServerRoot',('"'+$ServerRoot+'"'),'-InstanceId',([string]$Instance.id),'-OperationId',([string]$Tracked.id));if([bool]$Ui.InstanceIsolationCarbonCheck.IsChecked){$Args+='-IncludeCarbon'}
    $Process=Start-Process -FilePath $PsExe -ArgumentList $Args -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $Log -RedirectStandardError $ErrorLog -PassThru
    $null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Changes @{processId=[int]$Process.Id};Refresh-OperationCenter;Set-Activity 'Installation du runtime isolé lancée en arrière-plan.'
}

function Open-SelectedInstanceRuntime {
    $Instance=Get-SelectedServerInstance;if(-not$Instance){throw 'Sélectionne une instance.'};$Path=Get-RustInstanceRuntimeRoot -ServerRoot $ServerRoot -Instance $Instance;[IO.Directory]::CreateDirectory($Path)|Out-Null;Start-Process explorer.exe ('"'+$Path+'"')
}

$script:SupervisionCpuCache=@{}
$script:SupervisionChartHistory=New-Object Collections.Generic.List[object]

function Update-SupervisionChart([string]$InstanceId,[double]$CpuPercent,[double]$MemoryMb,[double]$MemoryMaxMb){
    $script:SupervisionChartHistory.Add([pscustomobject]@{InstanceId=$InstanceId;Cpu=$CpuPercent;Memory=$MemoryMb;At=Get-Date})
    while($script:SupervisionChartHistory.Count-gt120){$script:SupervisionChartHistory.RemoveAt(0)}
    $Rows=@($script:SupervisionChartHistory|Where-Object InstanceId -eq $InstanceId|Select-Object -Last 60);$Width=[math]::Max(100,[double]$Ui.SupervisionChartCanvas.ActualWidth);$Height=[math]::Max(80,[double]$Ui.SupervisionChartCanvas.ActualHeight)
    $CpuPoints=New-Object Windows.Media.PointCollection;$MemoryPoints=New-Object Windows.Media.PointCollection
    for($i=0;$i-lt$Rows.Count;$i++){$X=if($Rows.Count-le1){0}else{$i*($Width/($Rows.Count-1))};$CpuY=$Height-([math]::Min(100,[math]::Max(0,[double]$Rows[$i].Cpu))*$Height/100);$MemY=$Height-([math]::Min($MemoryMaxMb,[math]::Max(0,[double]$Rows[$i].Memory))*$Height/$MemoryMaxMb);$CpuPoints.Add([Windows.Point]::new($X,$CpuY));$MemoryPoints.Add([Windows.Point]::new($X,$MemY))}
    $Ui.SupervisionCpuLine.Points=$CpuPoints;$Ui.SupervisionMemoryLine.Points=$MemoryPoints
}

function Refresh-Supervision([switch]$IncludeRcon){
    $Id=[string]$Ui.SupervisionInstanceCombo.SelectedValue;if(-not$Id){$Instance=Get-RustServerInstance -ServerRoot $ServerRoot;$Id=[string]$Instance.id}else{$Instance=Get-RustServerInstance -ServerRoot $ServerRoot -Id $Id};if(-not$Instance){return}
    $Telemetry=Get-RustInstanceTelemetry -ServerRoot $ServerRoot -Instance $Instance -IncludeRcon:$IncludeRcon;$Now=Get-Date;$CpuPercent=0
    if($script:SupervisionCpuCache.ContainsKey($Id)){$Previous=$script:SupervisionCpuCache[$Id];$Elapsed=($Now-$Previous.At).TotalSeconds;if($Elapsed-gt0){$CpuPercent=[math]::Round((([double]$Telemetry.CpuSeconds-[double]$Previous.CpuSeconds)/$Elapsed/[Environment]::ProcessorCount)*100,1)}}
    $script:SupervisionCpuCache[$Id]=[pscustomobject]@{At=$Now;CpuSeconds=[double]$Telemetry.CpuSeconds};$Telemetry|Add-Member CpuPercent $CpuPercent -Force
    $CpuLabel=if($script:CurrentUiLanguage-eq'en-US'){[string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0:0.0} %',$CpuPercent)}else{('{0:0.0} %' -f $CpuPercent)};$RconLabel=if($Telemetry.RconMs-ge0){$Telemetry.Rcon+' '+$Telemetry.RconMs+' ms'}else{[string]$Telemetry.Rcon};if($script:CurrentUiLanguage-eq'en-US'){$RconLabel=ConvertTo-EnglishUiText $RconLabel};$Ui.SupervisionCpuText.Text=$CpuLabel;$Ui.SupervisionMemoryText.Text=('{0} {1}' -f $Telemetry.MemoryMb,(Get-LocalizedUiText 'Mo' 'MB'));$Ui.SupervisionUptimeText.Text=if($Telemetry.Running){Format-RustRpgDuration ([int]$Telemetry.UptimeSeconds)}else{Get-LocalizedUiText 'ARRÊTÉ' 'STOPPED'};$Ui.SupervisionRconText.Text=$RconLabel
    $Settings=Get-RustInstanceMonitorSettings -Instance $Instance;$Ui.SupervisionEnabledCheck.IsChecked=[bool]$Settings.Enabled;$Ui.SupervisionAutoRestartCheck.IsChecked=[bool]$Settings.AutoRestart;$Ui.SupervisionMaxRestartBox.Text=[string]$Settings.MaxRestartsHour;$Ui.SupervisionCooldownBox.Text=[string]$Settings.CooldownSeconds
    $Readiness=@(Get-RustStartReadinessDiagnostics -ServerRoot $ServerRoot -InstanceId $Id);if($script:CurrentUiLanguage-eq'en-US'){foreach($Row in $Readiness){foreach($Property in @('Status','Check','Detail','Action')){if($Row.PSObject.Properties.Name -contains $Property){$Row.$Property=ConvertTo-EnglishUiText ([string]$Row.$Property)}}}};$Ui.SupervisionReadinessGrid.ItemsSource=$Readiness
    $Events=@(Get-RustCrashEvents -ServerRoot $ServerRoot -InstanceId $Id|Select-Object -First 100|ForEach-Object{$EventDate=ConvertTo-RustUtcDate $_.utc;$Detail=[string]$_.detail;if($script:CurrentUiLanguage-eq'en-US'){$Detail=ConvertTo-EnglishUiText $Detail};[pscustomobject]@{Date=if($EventDate-ne[datetime]::MinValue){$EventDate.ToLocalTime().ToString('dd/MM HH:mm')}else{'—'};Type=[string]$_.type;Detail=$Detail}});$Ui.SupervisionEventGrid.ItemsSource=$Events;$Ui.SupervisionLastFailureText.Text=(Get-LocalizedUiText 'Dernière erreur : ' 'Last error: ')+[string]$Telemetry.LastFailure
    $Task=Get-RustWatchdogTaskStatus -ServerRoot $ServerRoot;$Ui.SupervisionTaskStatusText.Text=if($Task.Installed){(Get-LocalizedUiText 'Service actif : ' 'Service active: ')+$Task.State}else{Get-LocalizedUiText "Service non activé : la surveillance s’arrête avec l’application." 'Service disabled: monitoring stops when the app closes.'};$Ui.SupervisionInstallTaskButton.IsEnabled=-not$Task.Installed;$Ui.SupervisionRemoveTaskButton.IsEnabled=$Task.Installed
    Update-SupervisionChart -InstanceId $Id -CpuPercent $CpuPercent -MemoryMb ([double]$Telemetry.MemoryMb) -MemoryMaxMb ([math]::Max(4096,[double]$Instance.memoryEstimateGb*1024));if(-not$CapturePath){Save-RustTelemetrySnapshot -ServerRoot $ServerRoot -Samples @($Telemetry)}
}

function Save-SupervisionPolicy {
    $Id=[string]$Ui.SupervisionInstanceCombo.SelectedValue;if(-not$Id){throw 'Sélectionne une instance.'};$Max=0;$Cooldown=0;if(-not[int]::TryParse($Ui.SupervisionMaxRestartBox.Text,[ref]$Max)){throw 'Maximum de relances invalide.'};if(-not[int]::TryParse($Ui.SupervisionCooldownBox.Text,[ref]$Cooldown)){throw 'Délai de relance invalide.'};$null=Set-RustInstanceMonitorSettings -ServerRoot $ServerRoot -InstanceId $Id -Enabled ([bool]$Ui.SupervisionEnabledCheck.IsChecked) -AutoRestart ([bool]$Ui.SupervisionAutoRestartCheck.IsChecked) -MaxRestartsHour $Max -CooldownSeconds $Cooldown;Set-Activity 'Politique de supervision enregistrée.';Refresh-Supervision
}

$script:LastGeneratedRemoteToken=''
$script:RemoteAdvertisedUrls=@()
function Refresh-RemoteAccess {
    $Config=Get-RustRemoteAccessConfig -ServerRoot $ServerRoot
    $Ui.RemoteEnabledCheck.IsChecked=[bool]$Config.enabled
    $Ui.RemoteBindCombo.SelectedValue=[string]$Config.bindAddress
    $Ui.RemotePortBox.Text=[string]$Config.port
    $Ui.RemoteRconCheck.IsChecked=[bool]$Config.allowRcon
    $script:RemoteAdvertisedUrls=@(Get-RustRemoteAdvertisedUrls -ServerRoot $ServerRoot)
    $LocalUrl=@($script:RemoteAdvertisedUrls|Where-Object Kind -eq 'LOCAL'|Select-Object -First 1)
    $VpnUrls=@($script:RemoteAdvertisedUrls|Where-Object Kind -eq 'VPN')
    $Ui.RemoteUrlText.Text=if($LocalUrl.Count){[string]$LocalUrl[0].Url}else{"http://127.0.0.1:$($Config.port)/"}
    $Ui.RemoteVpnStatusText.Text=if($VpnUrls.Count){(Get-LocalizedUiText 'VPN détecté : ' 'VPN detected: ')+(($VpnUrls|ForEach-Object{$_.Adapter+' · '+$_.Address})-join', ')}elseif([string]$Config.bindAddress-eq'0.0.0.0'){Get-LocalizedUiText "Aucun VPN détecté ; l'adresse LAN reste réservée au réseau local." 'No VPN detected; the LAN address remains local-network only.'}else{Get-LocalizedUiText 'Écoute locale uniquement. Choisis Réseau local / VPN pour autoriser un VPN.' 'Local binding only. Select Local network / VPN to allow VPN access.'}
    $Ui.RemoteCopyVpnUrlButton.IsEnabled=$VpnUrls.Count-gt0
    $Task=Get-RustRemoteTaskStatus -ServerRoot $ServerRoot
    $Ui.RemoteServiceStatusText.Text=if($Task.Installed){(Get-LocalizedUiText 'INSTALLÉ · ' 'INSTALLED · ')+$Task.State}else{Get-LocalizedUiText 'NON INSTALLÉ' 'NOT INSTALLED'}
    $Ui.RemoteStartServiceButton.IsEnabled=-not$Task.Installed
    $Ui.RemoteStopServiceButton.IsEnabled=$Task.Installed
    $Processes=@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $Ui.RemoteTokenBox.Text=Get-LocalizedUiText 'Jeton masqué' 'Token hidden'
    $Ui.RemoteInstanceGrid.ItemsSource=@(Get-RustServerInstances -ServerRoot $ServerRoot|ForEach-Object{$RemoteInstance=$_;$S=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $RemoteInstance;$Running=@($Processes|Where-Object Identity -eq([string]$RemoteInstance.identity)).Count-gt0;$IsolationLabel=if($script:CurrentUiLanguage-eq'en-US'){if($S.Mode-eq'full'){'ISOLATED RUNTIME'}else{'SHARED RUNTIME'}}else{[string]$S.Label};[pscustomobject]@{DisplayName=[string]$RemoteInstance.displayName;State=if($Running){Get-LocalizedUiText 'ACTIF' 'RUNNING'}else{Get-LocalizedUiText 'ARRÊTÉ' 'STOPPED'};Port=[int]$RemoteInstance.serverPort;Isolation=$IsolationLabel}})
}
function Save-RemoteAccess {
    $Port=0;if(-not[int]::TryParse($Ui.RemotePortBox.Text,[ref]$Port)){throw 'Port web invalide.'};$null=Set-RustRemoteAccessConfig -ServerRoot $ServerRoot -Enabled ([bool]$Ui.RemoteEnabledCheck.IsChecked) -BindAddress ([string]$Ui.RemoteBindCombo.SelectedValue) -Port $Port -AllowRcon ([bool]$Ui.RemoteRconCheck.IsChecked);Refresh-RemoteAccess;Set-Activity "Configuration de l’accès distant enregistrée."
}
function Generate-RemoteToken {$script:LastGeneratedRemoteToken=New-RustRemoteAccessToken -ServerRoot $ServerRoot;$Ui.RemoteTokenBox.Text=$script:LastGeneratedRemoteToken;[Windows.Clipboard]::SetText($script:LastGeneratedRemoteToken);Show-Info "Le nouveau jeton a été copié dans le presse-papiers.`n`nIl ne sera plus affiché après fermeture de l’application." 'Jeton distant créé'}
function Copy-RemoteToken {if(-not$script:LastGeneratedRemoteToken){throw "Pour des raisons de sécurité, le jeton enregistré n’est pas relu dans l’interface. Génère-en un nouveau."};[Windows.Clipboard]::SetText($script:LastGeneratedRemoteToken);Set-Activity 'Jeton distant copié.'}
function Copy-RemoteVpnUrl {
    $VpnUrl=@($script:RemoteAdvertisedUrls|Where-Object Kind -eq 'VPN'|Select-Object -First 1)
    if(-not$VpnUrl.Count){throw "Aucune adresse VPN détectée. Connecte d'abord Tailscale, WireGuard, ZeroTier ou un VPN équivalent."}
    [Windows.Clipboard]::SetText([string]$VpnUrl[0].Url)
    Set-Activity 'Adresse VPN du tableau de bord copiée.'
}
function Test-RemoteDashboardAccess {
    $Config=Get-RustRemoteAccessConfig -ServerRoot $ServerRoot
    if(-not[bool]$Config.enabled){throw "Active d'abord le tableau de bord web."}
    $Url="http://127.0.0.1:$($Config.port)/health"
    try{$Health=Invoke-RestMethod -Uri $Url -TimeoutSec 4}catch{throw "Le service ne répond pas sur ce PC. Démarre le service puis réessaie. Détail : $($_.Exception.Message)"}
    if([string]$Health.status-ne'ok'){throw 'Le service a répondu avec un état inattendu.'}
    $VpnCount=@($script:RemoteAdvertisedUrls|Where-Object Kind -eq 'VPN').Count
    Show-Info ("Test local réussi.`n`nService : OK`nVersion : $($Health.version)`nAdresse : $Url`nVPN détectés : $VpnCount`n`nLe test depuis un autre appareil doit être effectué sur le même LAN ou VPN.")
}

$script:AvailableCatalog=@()
function Refresh-AvailablePluginCatalog {
    $Items=@(Get-RustAvailablePluginCatalog -ServerRoot $ServerRoot);$Registry=Get-RustInstalledPluginRegistry -ServerRoot $ServerRoot;$Selected=Get-RustServerInstance -ServerRoot $ServerRoot;$Search=$Ui.CatalogSearchBox.Text.Trim().ToLowerInvariant()
    $CategoryIndex=$Ui.CatalogCategoryCombo.SelectedIndex;$CategoryAliases=@(@(),@('Administration'),@('Gameplay'),@('Economy','Économie'),@('Utility','Utilitaire','Utilities','Utilitaires'),@('Other','Autre','Autres'));$AllowedCategories=if($CategoryIndex-ge0-and$CategoryIndex-lt$CategoryAliases.Count){@($CategoryAliases[$CategoryIndex])}else{@()}
    $Rows=foreach($P in $Items){$Entry=@($Registry.plugins|Where-Object{[string]$_.instanceId-eq[string]$Selected.id-and[string]$_.pluginId-eq[string]$P.Id})|Select-Object -First 1;$State=if($Entry){if([string]$Entry.version-ne[string]$P.Version){Get-LocalizedUiText 'MISE À JOUR' 'UPDATE'}else{Get-LocalizedUiText 'INSTALLÉ' 'INSTALLED'}}else{Get-LocalizedUiText 'DISPONIBLE' 'AVAILABLE'};$P|Add-Member InstallState $State -Force;if(((-not$Search)-or((($P.Name,$P.Description,$P.Author,$P.Category)-join' ').ToLowerInvariant().Contains($Search)))-and((-not$AllowedCategories.Count)-or([string]$P.Category-in$AllowedCategories))){$P}}
    $script:AvailableCatalog=@($Rows);$Ui.AvailablePluginGrid.ItemsSource=$script:AvailableCatalog;$InstalledCount=@($Registry.plugins|Where-Object instanceId -eq([string]$Selected.id)).Count;$Ui.CatalogSummaryText.Text=if($script:CurrentUiLanguage-eq'en-US'){"$($Items.Count) plugin(s) · $InstalledCount installed on $($Selected.displayName)"}else{"$($Items.Count) plugin(s) · $InstalledCount installé(s) sur $($Selected.displayName)"};Update-CatalogPluginInspector
}
function Update-CatalogPluginInspector {
    $P=$Ui.AvailablePluginGrid.SelectedItem;if(-not$P){$Ui.CatalogPluginTitleText.Text=Get-LocalizedUiText 'SÉLECTIONNE UN PLUGIN' 'SELECT A PLUGIN';$Ui.CatalogPluginDescriptionText.Text=Get-LocalizedUiText 'Les détails et dépendances apparaîtront ici.' 'Details and dependencies will appear here.';$Ui.CatalogCompatibilityText.Text='—';$Ui.CatalogDependenciesText.Text=Get-LocalizedUiText 'Aucune' 'None';$Ui.CatalogSourceText.Text='—';return};$Instance=Get-RustServerInstance -ServerRoot $ServerRoot;$Compatibility=Test-RustCatalogPluginCompatibility -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -Plugin $P;$Ui.CatalogPluginTitleText.Text=([string]$P.Name).ToUpperInvariant();$Ui.CatalogPluginDescriptionText.Text=[string]$P.Description;$CompatibilityText=[string]$Compatibility.Detail;if($script:CurrentUiLanguage-eq'en-US'){$CompatibilityText=ConvertTo-EnglishUiText $CompatibilityText};$Ui.CatalogCompatibilityText.Text=$CompatibilityText;$Ui.CatalogCompatibilityText.Foreground=$BrushConverter.ConvertFromString($(if($Compatibility.Compatible){'#72D79B'}else{'#E7A84D'}));$Ui.CatalogDependenciesText.Text=if(@($P.Dependencies).Count){@($P.Dependencies)-join', '}else{Get-LocalizedUiText 'Aucune' 'None'};$Ui.CatalogSourceText.Text=[string]$P.SourceName+' · '+[string]$P.Version;$Ui.CatalogHomepageButton.IsEnabled=[string]$P.Homepage-match'^https://';$Ui.CatalogInstallButton.IsEnabled=[bool]$Compatibility.Carbon;$Ui.CatalogRemoveButton.IsEnabled=[string]$P.InstallState-in@('INSTALLÉ','MISE À JOUR','INSTALLED','UPDATE')
}
function Sync-PluginCatalog {$Result=Sync-RustPluginCatalogSources -ServerRoot $ServerRoot;$Errors=@($Result.sources|Where-Object lastError);Refresh-AvailablePluginCatalog;if($Errors.Count){Show-Info (($Errors|ForEach-Object{$_.name+' : '+$_.lastError})-join"`n") 'Certaines sources ont échoué'}else{Set-Activity 'Catalogues de plugins synchronisés.'}}
function Add-PluginCatalogSource {$null=Add-RustPluginCatalogSource -ServerRoot $ServerRoot -Name $Ui.CatalogSourceNameBox.Text -Url $Ui.CatalogSourceUrlBox.Text.Trim();$Ui.CatalogSourceUrlBox.Text='';Sync-PluginCatalog}
function Start-CatalogPluginInstall {
    $P=$Ui.AvailablePluginGrid.SelectedItem;if(-not$P){throw 'Sélectionne un plugin.'};$Instance=Get-RustServerInstance -ServerRoot $ServerRoot;$Worker=Join-Path $PSScriptRoot 'RustRPG-PluginWorker.ps1';$Log=Get-OperationLogPath 'plugin-catalog';$ErrorLog=$Log+'.err';$Tracked=New-RustTrackedOperation -ServerRoot $ServerRoot -Type PluginCatalogInstall -Title ('Installation de '+[string]$P.Name) -ServerId ([string]$Instance.id) -Stage 'PRÉPARATION' -Detail 'Résolution du catalogue.' -RetryAction 'plugin-catalog-install' -CanCancel $true -LogPath $Log -ErrorLogPath $ErrorLog -Metadata ([pscustomobject]@{instanceId=[string]$Instance.id;pluginId=[string]$P.Id});$PsExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$Process=Start-Process -FilePath $PsExe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$Worker+'"'),'-ServerRoot',('"'+$ServerRoot+'"'),'-InstanceId',([string]$Instance.id),'-PluginId',([string]$P.Id),'-OperationId',([string]$Tracked.id)) -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $Log -RedirectStandardError $ErrorLog -PassThru;$null=Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Changes @{processId=[int]$Process.Id};Refresh-OperationCenter;Set-Activity 'Installation du plugin lancée en arrière-plan.'
}
function Remove-SelectedCatalogPlugin {$P=$Ui.AvailablePluginGrid.SelectedItem;if(-not$P){throw 'Sélectionne un plugin.'};$Instance=Get-RustServerInstance -ServerRoot $ServerRoot;if(-not(Confirm-Action "Archiver $($P.Name) sur $($Instance.displayName) ?" 'Retirer le plugin')){return};$null=Remove-RustCatalogPlugin -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -PluginId ([string]$P.Id);Refresh-AvailablePluginCatalog;Refresh-Plugins;Set-Activity 'Plugin archivé.'}

function Get-WizardIsPublic {
    return $script:WizardPreset -ne 'local'
}

function Get-WizardPresetLabel {
    switch ($script:WizardPreset) {
        'local' { return 'TEST LOCAL' }
        'community' { return 'COMMUNAUTÉ' }
        default { return 'ENTRE AMIS' }
    }
}

function ConvertTo-WizardSlug([string]$Text) {
    $Normalized = if ($Text) { $Text.Normalize([Text.NormalizationForm]::FormD) } else { '' }
    $Builder = New-Object Text.StringBuilder
    foreach ($Character in $Normalized.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($Character) -ne [Globalization.UnicodeCategory]::NonSpacingMark) { $null = $Builder.Append($Character) }
    }
    $Slug = $Builder.ToString().ToLowerInvariant() -replace '[^a-z0-9]+','-'
    $Slug = $Slug.Trim('-')
    if (-not $Slug) { $Slug = 'rust-server' }
    if ($Slug.Length -gt 32) { $Slug = $Slug.Substring(0,32).TrimEnd('-') }
    return $Slug
}

function Get-UniqueWizardIdentity([string]$BaseIdentity) {
    $Base = ConvertTo-WizardSlug $BaseIdentity
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Index = 1
    while ($true) {
        $Suffix = if ($Index -eq 1) { '' } else { '-' + [string]$Index }
        $MaxBaseLength = 32 - $Suffix.Length
        $CandidateBase = if ($Base.Length -gt $MaxBaseLength) { $Base.Substring(0,$MaxBaseLength).TrimEnd('-') } else { $Base }
        $Candidate = $CandidateBase + $Suffix
        $Known = @($Catalog.instances | Where-Object { [string]$_.id -eq $Candidate -or [string]$_.identity -eq $Candidate }).Count -gt 0
        $PathExists = Test-Path -LiteralPath (Join-Path $ServerRoot ('server\server\' + $Candidate))
        if (-not $Known -and -not $PathExists) { return $Candidate }
        $Index++
    }
}

function Set-WizardPreset([ValidateSet('local','friends','community')][string]$Preset) {
    $script:WizardPreset = $Preset
    $Definitions = @{
        local = [pscustomobject]@{ Name='Serveur local'; Identity='serveur-local'; WorldSize=2000; MaxPlayers=5; Memory=6 }
        friends = [pscustomobject]@{ Name='Serveur amis'; Identity='serveur-amis'; WorldSize=2500; MaxPlayers=10; Memory=6 }
        community = [pscustomobject]@{ Name='Serveur communauté'; Identity='serveur-communaute'; WorldSize=3500; MaxPlayers=50; Memory=8 }
    }
    $Definition = $Definitions[$Preset]
    $Ui.WizardNameBox.Text = [string]$Definition.Name
    $Ui.WizardIdentityBox.Text = Get-UniqueWizardIdentity ([string]$Definition.Identity)
    $Ui.WizardWorldSizeCombo.SelectedItem = [int]$Definition.WorldSize
    $Ui.WizardMaxPlayersBox.Text = [string]$Definition.MaxPlayers
    $Ui.WizardMemoryBox.Text = [string]$Definition.Memory
    $Ui.WizardPresetLocalRadio.IsChecked = $Preset -eq 'local'
    $Ui.WizardPresetFriendsRadio.IsChecked = $Preset -eq 'friends'
    $Ui.WizardPresetCommunityRadio.IsChecked = $Preset -eq 'community'
    foreach ($Entry in @(
        [pscustomobject]@{ Name='local'; Border=$Ui.WizardPresetLocalBorder },
        [pscustomobject]@{ Name='friends'; Border=$Ui.WizardPresetFriendsBorder },
        [pscustomobject]@{ Name='community'; Border=$Ui.WizardPresetCommunityBorder }
    )) {
        $Selected = $Entry.Name -eq $Preset
        $Entry.Border.Background = $BrushConverter.ConvertFromString($(if ($Selected) { '#291913' } else { '#171614' }))
        $Entry.Border.BorderBrush = $BrushConverter.ConvertFromString($(if ($Selected) { '#D65332' } else { '#403A34' }))
        $Entry.Border.BorderThickness = if ($Selected) { [Windows.Thickness]::new(4,1,1,1) } else { [Windows.Thickness]::new(1) }
        $Entry.Border.Padding = if ($Selected) { [Windows.Thickness]::new(11,10,14,10) } else { [Windows.Thickness]::new(14,10,14,10) }
    }
    $Ui.WizardPublicInfoBorder.Visibility = if (Get-WizardIsPublic) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    Update-WizardResourceText
}

function Set-WizardAutomaticPorts {
    $Ports = Get-RustAvailablePortSet -ServerRoot $ServerRoot
    $Ui.WizardServerPortBox.Text = [string]$Ports.ServerPort
    $Ui.WizardRconPortBox.Text = [string]$Ports.RconPort
    $Ui.WizardQueryPortBox.Text = [string]$Ports.QueryPort
    $Ui.WizardAppPortBox.Text = [string]$Ports.AppPort
    $Ui.WizardPortsStatusText.Text = "Bloc libre détecté : $($Ports.ServerPort) à $($Ports.AppPort)."
    $Ui.WizardPortsStatusText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
}

function Update-WizardPortEditingState {
    $Automatic = [bool]$Ui.WizardAutoPortsCheck.IsChecked
    foreach ($Box in @($Ui.WizardServerPortBox,$Ui.WizardRconPortBox,$Ui.WizardQueryPortBox,$Ui.WizardAppPortBox)) { $Box.IsEnabled = -not $Automatic }
    if ($Automatic) { Set-WizardAutomaticPorts }
    else {
        $Ui.WizardPortsStatusText.Text = 'Les ports personnalisés seront vérifiés avant la création.'
        $Ui.WizardPortsStatusText.Foreground = $BrushConverter.ConvertFromString('#C78132')
    }
}

function Update-WizardMapControls {
    $Custom = (Get-SelectedText $Ui.WizardMapTypeCombo) -eq 'Custom URL'
    $Ui.WizardLevelUrlBox.IsEnabled = $Custom
    $Ui.WizardMapHelpText.Text = if ($Custom) { 'Utilise une URL directe. Pour un serveur public, elle doit commencer par http:// ou https://.' } else { 'Rust générera cette carte au premier démarrage.' }
}

function Update-WizardResourceText {
    $Memory = 0
    if (-not [int]::TryParse([string]$Ui.WizardMemoryBox.Text,[ref]$Memory)) { $Memory = 0 }
    $Ui.WizardResourceText.Text = if ($Memory -gt 0) { "Cette instance utilisera environ $Memory Go de RAM lorsqu’elle sera active." } else { 'Indique une estimation mémoire valide.' }
}

function Test-WizardIdentityAvailable([string]$Identity) {
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    if (@($Catalog.instances | Where-Object { [string]$_.id -eq $Identity -or [string]$_.identity -eq $Identity }).Count) { throw "Le dossier interne '$Identity' existe déjà." }
    $Path = Join-Path $ServerRoot ('server\server\' + $Identity)
    if (Test-Path -LiteralPath $Path) { throw "Le dossier '$Path' contient déjà des données. Choisis un autre nom." }
}

function Get-WizardPortValues {
    return @(
        (ConvertTo-InstancePort $Ui.WizardServerPortBox.Text 'Port jeu'),
        (ConvertTo-InstancePort $Ui.WizardRconPortBox.Text 'Port RCON'),
        (ConvertTo-InstancePort $Ui.WizardQueryPortBox.Text 'Port query'),
        (ConvertTo-InstancePort $Ui.WizardAppPortBox.Text 'Port Rust+')
    )
}

function Test-WizardStep([ValidateRange(1,5)][int]$Step) {
    switch ($Step) {
        1 {
            $Name = $Ui.WizardNameBox.Text.Trim()
            $Identity = $Ui.WizardIdentityBox.Text.Trim().ToLowerInvariant()
            if (-not $Name -or $Name.Length -gt 80) { throw 'Le nom du serveur doit contenir entre 1 et 80 caractères.' }
            if ($Identity -notmatch '^[a-z0-9][a-z0-9-]{0,31}$') { throw 'Le dossier interne accepte uniquement lettres minuscules, chiffres et tirets.' }
            Test-WizardIdentityAvailable $Identity
        }
        2 {
            $Ports = Get-WizardPortValues
            Assert-RustNewInstancePorts -ServerRoot $ServerRoot -Ports $Ports
            $Ui.WizardPortsStatusText.Text = 'Ports disponibles et sans collision.'
            $Ui.WizardPortsStatusText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
        }
        3 {
            $Seed = 0L
            if (-not [long]::TryParse($Ui.WizardSeedBox.Text,[ref]$Seed) -or $Seed -lt 0 -or $Seed -gt 2147483647) { throw 'Seed attendue entre 0 et 2147483647.' }
            $Size = 0
            if (-not [int]::TryParse([string]$Ui.WizardWorldSizeCombo.SelectedItem,[ref]$Size) -or $Size -lt 1000 -or $Size -gt 6000) { throw 'Taille de carte invalide.' }
            if ((Get-SelectedText $Ui.WizardMapTypeCombo) -eq 'Custom URL') {
                $Url = $Ui.WizardLevelUrlBox.Text.Trim()
                if (-not $Url) { throw 'Indique une URL de carte custom.' }
                if ((Get-WizardIsPublic) -and $Url -notmatch '^https?://') { throw 'Une carte custom publique exige une URL HTTP/HTTPS.' }
            }
        }
        4 {
            $MaxPlayers = 0; $SaveInterval = 0; $Memory = 0
            if (-not [int]::TryParse($Ui.WizardMaxPlayersBox.Text,[ref]$MaxPlayers) -or $MaxPlayers -lt 1 -or $MaxPlayers -gt 500) { throw 'Joueurs maximum : valeur attendue entre 1 et 500.' }
            if (-not [int]::TryParse($Ui.WizardSaveIntervalBox.Text,[ref]$SaveInterval) -or $SaveInterval -lt 30 -or $SaveInterval -gt 3600) { throw 'Sauvegarde : valeur attendue entre 30 et 3600 secondes.' }
            if (-not [int]::TryParse($Ui.WizardMemoryBox.Text,[ref]$Memory) -or $Memory -lt 4 -or $Memory -gt 32) { throw 'RAM estimée : valeur attendue entre 4 et 32 Go.' }
        }
        5 {
            foreach ($PreviousStep in 1..4) { Test-WizardStep $PreviousStep }
        }
    }
    return $true
}

function Update-WizardSummary {
    $Ports = Get-WizardPortValues
    $PveLabel = if ([bool]$Ui.WizardPveCheck.IsChecked) { 'PvE activé' } else { 'PvE désactivé' }
    $MapType = Get-SelectedText $Ui.WizardMapTypeCombo
    $MapDetail = if ($MapType -eq 'Custom URL') { 'Carte custom • ' + $Ui.WizardLevelUrlBox.Text.Trim() } else { "Procédurale • $($Ui.WizardWorldSizeCombo.SelectedItem) m • seed $($Ui.WizardSeedBox.Text)" }
    $Ui.WizardSummaryProfileText.Text = "$($Ui.WizardNameBox.Text.Trim())`n$(Get-WizardPresetLabel)"
    $Ui.WizardSummaryMapText.Text = $MapDetail
    $Ui.WizardSummaryPlayersText.Text = "$($Ui.WizardMaxPlayersBox.Text) maximum • $PveLabel"
    $Ui.WizardSummaryPortsText.Text = "Jeu $($Ports[0]) • RCON $($Ports[1]) • Query $($Ports[2]) • Rust+ $($Ports[3])"
    $Ui.WizardSummaryResourcesText.Text = "Environ $($Ui.WizardMemoryBox.Text) Go de RAM"
    $Ui.WizardSummarySaveText.Text = "Toutes les $($Ui.WizardSaveIntervalBox.Text) secondes"
    $Ui.WizardSummaryNetworkBorder.Visibility = if (Get-WizardIsPublic) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
}

function Set-WizardStep([ValidateRange(1,6)][int]$Step) {
    $script:WizardStep = $Step
    $Panels = @($Ui.WizardStep1Panel,$Ui.WizardStep2Panel,$Ui.WizardStep3Panel,$Ui.WizardStep4Panel,$Ui.WizardStep5Panel)
    for ($Index = 0; $Index -lt $Panels.Count; $Index++) { $Panels[$Index].Visibility = if (($Index + 1) -eq $Step) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed } }
    $Ui.WizardSuccessPanel.Visibility = if ($Step -eq 6) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.WizardFooterPanel.Visibility = if ($Step -eq 6) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Borders = @($Ui.WizardStep1Border,$Ui.WizardStep2Border,$Ui.WizardStep3Border,$Ui.WizardStep4Border,$Ui.WizardStep5Border)
    $Numbers = @($Ui.WizardStep1Number,$Ui.WizardStep2Number,$Ui.WizardStep3Number,$Ui.WizardStep4Number,$Ui.WizardStep5Number)
    $Done = @($Ui.WizardStep1DoneText,$Ui.WizardStep2DoneText,$Ui.WizardStep3DoneText,$Ui.WizardStep4DoneText,$Ui.WizardStep5DoneText)
    for ($Index = 0; $Index -lt 5; $Index++) {
        $Number = $Index + 1
        $Selected = $Number -eq $Step
        $Completed = $Number -lt $Step
        $Borders[$Index].Background = $BrushConverter.ConvertFromString($(if ($Selected) { '#D65332' } elseif ($Completed) { '#24422E' } else { '#2A2723' }))
        $Numbers[$Index].Foreground = $BrushConverter.ConvertFromString($(if ($Selected) { '#FFF8ED' } elseif ($Completed) { '#9FD36F' } else { '#9B9288' }))
        $Numbers[$Index].FontWeight = if ($Selected) { [Windows.FontWeights]::Bold } else { [Windows.FontWeights]::Normal }
        $Done[$Index].Text = if ($Completed) { [string][char]0x2713 } else { '' }
    }
    if ($Step -le 5) {
        $Ui.WizardBackButton.Visibility = if ($Step -eq 1) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
        $Ui.WizardStepCounterText.Text = "ÉTAPE $Step SUR 5"
        $Ui.WizardNextButton.Content = if ($Step -eq 5) { 'CRÉER LE SERVEUR' } else { 'CONTINUER' }
        if ($Step -eq 2) { Update-WizardPortEditingState }
        if ($Step -eq 5) { Update-WizardSummary }
    }
}

function Initialize-ServerWizard {
    $script:WizardCreatedInstance = $null
    $Ui.WizardMapTypeCombo.DisplayMemberPath='Label'
    $Ui.WizardMapTypeCombo.SelectedValuePath='Code'
    $Ui.WizardMapTypeCombo.ItemsSource = @([pscustomobject]@{Code='Procedurale';Label=if($script:CurrentUiLanguage-eq'en-US'){'Procedural'}else{'Procédurale'}},[pscustomobject]@{Code='Custom URL';Label='Custom URL'})
    $Ui.WizardMapTypeCombo.SelectedValue = 'Procedurale'
    $Ui.WizardWorldSizeCombo.ItemsSource = @(1000,1500,2000,2500,3000,3500,4000,4500,5000,5500,6000)
    $Ui.WizardSaveIntervalBox.Text = '300'
    $Ui.WizardSeedBox.Text = [string](Get-Random -Minimum 0 -Maximum 2147483647)
    $Ui.WizardLevelUrlBox.Text = ''
    $Ui.WizardEnabledCheck.IsChecked = $true
    $Ui.WizardAutoPortsCheck.IsChecked = $true
    $Ui.WizardPveCheck.IsChecked = $false
    $Ui.WizardCreativeCheck.IsChecked = $false
    $Ui.WizardSelectAfterCheck.IsChecked = $true
    Set-WizardPreset friends
    Set-WizardAutomaticPorts
    Update-WizardMapControls
    Set-WizardStep 1
}

function Open-ServerWizard([int]$ReturnTab = -1) {
    $script:WizardReturnTab = $ReturnTab
    Initialize-ServerWizard
    $script:WizardNavigationGuard = $true
    try {
        $Navigation = if ($script:InterfaceMode -eq 'simple') { $Ui.SimpleNavigation } else { $Ui.Navigation }
        $TargetTag = if ($script:InterfaceMode -eq 'simple') { 13 } else { 1 }
        for ($Index = 0; $Index -lt $Navigation.Items.Count; $Index++) { if ($null -ne $Navigation.Items[$Index].Tag -and [int]$Navigation.Items[$Index].Tag -eq $TargetTag) { $Navigation.SelectedIndex = $Index; break } }
        $Ui.MainTabs.SelectedIndex = 15
    }
    finally { $script:WizardNavigationGuard = $false }
    Set-Activity 'Assistant de création ouvert. Aucun fichier ne sera modifié avant la dernière étape.'
}

function Close-ServerWizard {
    if ($script:WizardReturnTab -ge 0) { Open-ControlCenterTab $script:WizardReturnTab }
    elseif ($script:InterfaceMode -eq 'simple') { Open-ControlCenterTab 13 }
    else { Open-ControlCenterTab 1 }
    Refresh-Instances
    if ($script:WizardReturnTab -eq 18) { Refresh-Onboarding }
    $script:WizardReturnTab = -1
    if ($script:WizardCreatedInstance) { Set-Activity "Serveur '$($script:WizardCreatedInstance.displayName)' créé. Rust n'a pas été démarré." }
    else { Set-Activity "Assistant fermé. Aucun serveur n'a été créé." }
}

function Complete-ServerWizardCreation {
    $null = Test-WizardStep 5
    $Ports = Get-WizardPortValues
    $Seed = [long]$Ui.WizardSeedBox.Text
    $WorldSize = [int]$Ui.WizardWorldSizeCombo.SelectedItem
    $MaxPlayers = [int]$Ui.WizardMaxPlayersBox.Text
    $SaveInterval = [int]$Ui.WizardSaveIntervalBox.Text
    $Memory = [int]$Ui.WizardMemoryBox.Text
    $Identity = $Ui.WizardIdentityBox.Text.Trim().ToLowerInvariant()
    $Name = $Ui.WizardNameBox.Text.Trim()
    $MapType = Get-SelectedText $Ui.WizardMapTypeCombo
    $LevelUrl = $Ui.WizardLevelUrlBox.Text.Trim()
    $Instance = Invoke-TrackedSynchronousAction -Type ServerCreate -Title ("Création de " + $Name) -ServerId $Identity -Stage 'VALIDATION & CRÉATION' -Detail 'Le profil, les ports et les fichiers de configuration sont créés sans démarrer Rust.' -Action {
        New-RustServerInstanceFromProfile -ServerRoot $ServerRoot -DisplayName $Name -Identity $Identity -Enabled ([bool]$Ui.WizardEnabledCheck.IsChecked) -IsPublic (Get-WizardIsPublic) -ServerPort $Ports[0] -RconPort $Ports[1] -QueryPort $Ports[2] -AppPort $Ports[3] -MapType $MapType -LevelUrl $LevelUrl -Seed $Seed -WorldSize $WorldSize -MaxPlayers $MaxPlayers -SaveInterval $SaveInterval -MemoryEstimateGb $Memory -Pve ([bool]$Ui.WizardPveCheck.IsChecked) -Creative ([bool]$Ui.WizardCreativeCheck.IsChecked) -SelectAfterCreation ([bool]$Ui.WizardSelectAfterCheck.IsChecked)
    }
    $script:WizardCreatedInstance = $Instance
    Refresh-Instances
    Refresh-SimpleServers
    Update-NetworkHeader
    $Ui.WizardSuccessText.Text = "Le profil '$($Instance.displayName)' est prêt. Les serveurs existants et leurs mondes sont restés inchangés."
    $Ui.WizardSuccessAddressText.Text = "client.connect 127.0.0.1:$($Instance.serverPort)"
    $Ui.WizardSuccessNetworkButton.Visibility = if ([bool]$Instance.isPublic) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    Set-WizardStep 6
    Set-Activity "Serveur '$($Instance.displayName)' créé sans démarrage automatique."
}

function Move-ServerWizardNext {
    $null = Test-WizardStep $script:WizardStep
    if ($script:WizardStep -lt 5) { Set-WizardStep ($script:WizardStep + 1) }
    else { Complete-ServerWizardCreation }
}

function Move-ServerWizardBack {
    if ($script:WizardStep -gt 1 -and $script:WizardStep -le 5) { Set-WizardStep ($script:WizardStep - 1) }
}

function Remove-SelectedInstance {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { throw 'Sélectionne une instance.' }
    if (-not (Confirm-Action "Retirer '$($Instance.displayName)' du catalogue ?`n`nLe monde et les fichiers restent sur le disque et ne seront pas supprimés." 'Retirer une instance')) { return }
    $Identity = Remove-RustServerInstance -ServerRoot $ServerRoot -Id ([string]$Instance.id)
    Refresh-Instances
    Set-Activity "Instance retirée. Les données techniques '$Identity' sont conservées."
}

function Get-SelectedConnectCommand {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { return 'client.connect 127.0.0.1:28115' }
    if ([bool]$Instance.isPublic) {
        return [regex]::Replace((Get-FriendCommand),':\d+$',(':' + [string]$Instance.serverPort))
    }
    return "client.connect 127.0.0.1:$($Instance.serverPort)"
}

function Select-SimpleInstance([bool]$Public) {
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object { [bool]$_.isPublic -eq $Public }) | Select-Object -First 1
    if (-not $Instance) {
        $Purpose = if ($Public) { 'publique' } else { 'locale' }
        throw "Aucune instance $Purpose n'est configurée. Crée-la dans Mes serveurs."
    }
    if ([string]$Catalog.selectedId -ne [string]$Instance.id) {
        $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id ([string]$Instance.id)
        Refresh-Instances
    }
    return $Instance
}

function Invoke-SimpleLocalAction {
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object { -not [bool]$_.isPublic }) | Select-Object -First 1
    if (-not $Instance) {
        Open-SimpleDestination 1
        Set-Activity 'Crée ou duplique une instance, puis décoche « Publique » pour préparer ton serveur local.'
        return
    }
    $Instance = Select-SimpleInstance -Public $false
    $ServerExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
    if (-not (Test-Path -LiteralPath $ServerExe)) {
        Start-ServerUpdate
        Set-Activity 'Installation du serveur vanilla lancée en silence. Le bouton deviendra DÉMARRER une fois terminée.'
        return
    }
    $Process = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
    if ($Process) { Join-RustServer }
    else { Start-RustInstance -Id ([string]$Instance.id) }
}

function Invoke-SimpleFriendsAction {
    $Instance = Select-SimpleInstance -Public $true
    $Command = Get-SelectedConnectCommand
    [Windows.Clipboard]::SetText($Command)
    # Onglet 12 : l'assistant en cinq etapes, pas la page reseau technique.
    Open-SimpleDestination 12
    Set-Activity "Adresse copiée : $Command. Suis les cinq étapes pour que tes amis puissent entrer."
}

function Start-RustInstance([string]$Id,[switch]$SkipAdditionalConfirmation) {
    if (Test-ControlCenterUpdateRunning) { throw 'Attends la fin de la mise à jour avant de démarrer un serveur.' }
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = @($Catalog.instances | Where-Object id -eq $Id) | Select-Object -First 1
    if (-not $Instance) { throw "Instance '$Id' introuvable." }
    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    if (@($Processes | Where-Object Identity -eq ([string]$Instance.identity)).Count) { throw 'Cette instance est déjà active.' }
    if ($Processes.Count -and -not [bool]$Catalog.allowMultiInstance) { throw 'Une autre instance est active. Active explicitement le mode multi-instance pour continuer.' }
    if ($Processes.Count -and -not $SkipAdditionalConfirmation) {
        $ExistingSharedCarbon=@($Processes|ForEach-Object{Get-RustServerInstance -ServerRoot $ServerRoot -Id ([string]$_.InstanceId)}|Where-Object{$_ -and [string]$_.isolationMode-ne'full' -and (Get-RustModEnvironment -ServerRoot $ServerRoot -InstanceId ([string]$_.id)).Installed})
        $TargetIsolation=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Instance
        if($ExistingSharedCarbon.Count -and $TargetIsolation.Mode-ne'full'){throw 'Multi-instance Carbon refusé : isole chaque runtime Carbon avant de lancer plusieurs processus.'}
        if (-not (Confirm-Action "Démarrer une deuxième instance ?`n`nChaque serveur peut consommer 5 à 8 Go de RAM. Les ports sont vérifiés et les runtimes Carbon doivent être isolés.`n`nContinue seulement pour un test surveillé." 'Multi-instance expérimental')) { return }
    }
    $Os = Get-CimInstance Win32_OperatingSystem
    $FreeRamGb = [math]::Round([double]$Os.FreePhysicalMemory / 1MB,1)
    if ($FreeRamGb -lt ([double]$Instance.memoryEstimateGb + 2) -and -not $SkipAdditionalConfirmation) {
        if (-not (Confirm-Action "RAM libre : $FreeRamGb Go. Estimation pour cette instance : $($Instance.memoryEstimateGb) Go.`n`nLe PC peut ralentir ou RustDedicated peut s'arrêter. Continuer ?" 'Mémoire limitée')) { return }
    }
    $Launcher = Join-Path $ServerRoot 'Start-Instance.ps1'
    if (-not (Test-Path -LiteralPath $Launcher)) { throw 'Le lanceur Start-Instance.ps1 est introuvable.' }
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $LauncherErrorLog = Join-Path $ServerRoot ('logs\launcher-' + [string]$Instance.id + '-error.log')
    $LauncherProcess = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"' + $Launcher + '"'),'-InstanceId',([string]$Instance.id)) -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardError $LauncherErrorLog -PassThru
    $null = Set-RustDesiredState -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -State Running -Reason user
    $OperationLog = Get-OperationLogPath 'server-start'
    Write-TrackedOperationLog $OperationLog ("Lanceur silencieux démarré pour $($Instance.displayName), PID $($LauncherProcess.Id).")
    $Tracked = New-RustTrackedOperation -ServerRoot $ServerRoot -Type ServerStart -Title ("Démarrage de " + [string]$Instance.displayName) -ServerId ([string]$Instance.id) -Stage 'LANCEMENT' -Detail 'Le lanceur prépare les fichiers puis charge RustDedicated.' -RetryAction 'server-start' -CanCancel $true -LogPath $OperationLog -ErrorLogPath $LauncherErrorLog -ProcessId ([int]$LauncherProcess.Id) -Metadata ([pscustomobject]@{ instanceId=[string]$Instance.id; identity=[string]$Instance.identity })
    Refresh-OperationCenter
    Set-Activity "Démarrage de '$($Instance.displayName)' sur UDP $($Instance.serverPort)..."
}

function Start-SelectedInstance {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { throw 'Sélectionne une instance.' }
    Start-RustInstance -Id ([string]$Instance.id)
}

function Start-EnabledInstances {
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $Pending = @($Catalog.instances | Where-Object { [bool]$_.enabled -and -not @($Processes | Where-Object Identity -eq ([string]$_.identity)).Count })
    if (-not $Pending.Count) { throw 'Toutes les instances activées sont déjà lancées.' }
    if (($Processes.Count + $Pending.Count) -gt 1 -and -not [bool]$Catalog.allowMultiInstance) { throw "Coche d'abord l'acceptation du mode multi-instance expérimental." }
    if(($Processes.Count+$Pending.Count)-gt1){
        $AllTargetIds=@($Processes.InstanceId)+@($Pending.id)
        if(-not$Processes.Count){
            $Plan=Get-RustMultiInstanceReadiness -ServerRoot $ServerRoot -InstanceIds @($Pending.id)
            if(-not$Plan.Ready){throw "Préparation multi-instance refusée :`n`n"+(($Plan.Blocking|ForEach-Object{$_.Check+' : '+$_.Detail+' '+$_.Action})-join"`n")}
        }
        $UnsafeCarbon=@($Catalog.instances|Where-Object{[string]$_.id-in$AllTargetIds -and [string]$_.isolationMode-ne'full' -and (Get-RustModEnvironment -ServerRoot $ServerRoot -InstanceId ([string]$_.id)).Installed})
        if($UnsafeCarbon.Count){throw 'Lancement groupé refusé : chaque instance Carbon doit utiliser un runtime complet isolé.'}
    }
    $Estimate = (($Pending | Measure-Object -Property memoryEstimateGb -Sum).Sum)
    if (-not (Confirm-Action "Lancer $($Pending.Count) instance(s) ?`n`nEstimation supplémentaire : environ $Estimate Go de RAM. Les plugins Carbon peuvent ne pas supporter plusieurs processus partageant la même installation.`n`nLes instances seront lancées silencieusement." 'Lancer plusieurs instances')) { return }
    foreach ($Instance in $Pending) { Start-RustInstance -Id ([string]$Instance.id) -SkipAdditionalConfirmation }
}

function Stop-SelectedInstance {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { throw 'Sélectionne une instance.' }
    $Process = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1
    if (-not $Process) { throw 'Cette instance est déjà arrêtée.' }
    if (-not (Confirm-Action "Sauvegarder puis arrêter '$($Instance.displayName)' ?" 'Arrêter une instance')) { return }
    $null = Set-RustDesiredState -ServerRoot $ServerRoot -InstanceId ([string]$Instance.id) -State Stopped -Reason user
    try { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Instance.rconPort) -Command 'server.save' -TimeoutMs 8000 } catch { }
    $null = Send-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Instance.rconPort) -Command 'quit'
    Set-Activity "Arrêt demandé à '$($Instance.displayName)'."
}

function Stop-AllServerInstances {
    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    if (-not $Processes.Count) { throw 'Aucune instance active.' }
    if (-not (Confirm-Action "Sauvegarder puis arrêter les $($Processes.Count) instance(s) actives ?" 'Arrêter toutes les instances')) { return }
    foreach ($Process in $Processes) {
        if([string]$Process.InstanceId){$null=Set-RustDesiredState -ServerRoot $ServerRoot -InstanceId ([string]$Process.InstanceId) -State Stopped -Reason user}
        try { $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Process.RconPort) -Command 'server.save' -TimeoutMs 8000 } catch { }
        try { $null = Send-RustRpgRconCommand -ServerRoot $ServerRoot -RconPort ([int]$Process.RconPort) -Command 'quit' } catch { Set-Activity "Arrêt RCON impossible pour $($Process.DisplayName) : $($_.Exception.Message)" }
    }
}

function Update-RuntimeDisplay {
    try {
        $null = Complete-PublicIpLookup
        $State = Get-RustRpgServerState -ServerRoot $ServerRoot
        $Running = $State.Running
        $StateLabel=if($Running){Get-LocalizedUiText 'ACTIF' 'RUNNING'}else{Get-LocalizedUiText 'ARRÊTÉ' 'STOPPED'}
        $Ui.TopStatusText.Text = $StateLabel
        $Ui.DashStateText.Text = $StateLabel
        $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
        $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
        $Selected = Get-SelectedServerInstance
        $SelectedProcess = if ($Selected) { @($Processes | Where-Object Identity -eq ([string]$Selected.identity)) | Select-Object -First 1 } else { $null }
        foreach ($Row in @($Ui.InstanceGrid.ItemsSource)) {
            $RowProcess = @($Processes | Where-Object Identity -eq ([string]$Row.Identity)) | Select-Object -First 1
            $Row.Etat = if ($RowProcess) { Get-LocalizedUiText 'ACTIF' 'RUNNING' } else { Get-LocalizedUiText 'ARRÊTÉ' 'STOPPED' }
            $Row.Pid = if ($RowProcess) { [int]$RowProcess.ProcessId } else { 0 }
        }
        $Ui.InstanceGrid.Items.Refresh()
        $RuntimeLines = @($Processes | ForEach-Object { '{0} - PID {1} - UDP {2} - {3} Mo' -f $_.DisplayName,$_.ProcessId,$_.ServerPort,$_.MemoryMb })
        $Ui.ServerRuntimeText.Text = if ($RuntimeLines.Count) { $RuntimeLines -join "`n" } else { Get-LocalizedUiText 'Aucune instance active' 'No running instances' }
        if ($Running) {
            $Ui.TopStatusBorder.Background = $BrushConverter.ConvertFromString('Transparent')
            $Ui.TopStatusDot.Fill = $BrushConverter.ConvertFromString('#72D79B')
            $Ui.DashStateText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
            $MemoryMb = ($Processes | Measure-Object -Property MemoryMb -Sum).Sum
            $Ui.DashMemoryText.Text = "$MemoryMb $(Get-LocalizedUiText 'Mo' 'MB')"
        }
        else {
            $Ui.TopStatusBorder.Background = $BrushConverter.ConvertFromString('Transparent')
            $Ui.TopStatusDot.Fill = $BrushConverter.ConvertFromString('#D65332')
            $Ui.DashStateText.Foreground = $BrushConverter.ConvertFromString('#D65332')
            $Ui.DashMemoryText.Text = Get-LocalizedUiText '0 Mo' '0 MB'
        }

        $UpdateBusy = Test-ControlCenterUpdateRunning
        $CanStartSelected = $Selected -and -not $SelectedProcess -and (-not $Running -or [bool]$Catalog.allowMultiInstance) -and -not $UpdateBusy
        $PendingEnabled = @($Catalog.instances | Where-Object { [bool]$_.enabled -and -not @($Processes | Where-Object Identity -eq ([string]$_.identity)).Count })
        $Ui.DashLocalButton.IsEnabled = [bool]$CanStartSelected
        $Ui.DashOnlineButton.IsEnabled = $true
        $Ui.ServerLocalButton.IsEnabled = [bool]$CanStartSelected
        $Ui.ServerOnlineButton.IsEnabled = ($PendingEnabled.Count -gt 0 -and -not $UpdateBusy)
        $Ui.UpdateServerButton.IsEnabled = (-not $Running -and -not $UpdateBusy)
        $Ui.DashUpdateButton.IsEnabled = (-not $Running -and -not $UpdateBusy)
        $Ui.DashStopButton.IsEnabled = [bool]$SelectedProcess
        $Ui.ServerStopButton.IsEnabled = [bool]$SelectedProcess
        $Ui.DashJoinButton.IsEnabled = [bool]$SelectedProcess
        $Ui.ServerJoinButton.IsEnabled = [bool]$SelectedProcess
        $Ui.StopAllInstancesButton.IsEnabled = $Running
        $Ui.HeaderStartButton.IsEnabled = [bool](($CanStartSelected -or $SelectedProcess) -and -not $UpdateBusy)
        $Ui.HeaderStartButton.Content = if ($SelectedProcess) { Get-LocalizedUiText 'ARRÊTER' 'STOP' } else { Get-LocalizedUiText 'DÉMARRER' 'START' }
        $Ui.HeaderStartButton.Background = $BrushConverter.ConvertFromString($(if ($SelectedProcess) { '#9E2D26' } else { '#D65332' }))
        $LocalInstance = @($Catalog.instances | Where-Object { -not [bool]$_.isPublic }) | Select-Object -First 1
        $LocalProcess = if ($LocalInstance) { @($Processes | Where-Object Identity -eq ([string]$LocalInstance.identity)) | Select-Object -First 1 } else { $null }
        $ServerInstalled = Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe')
        if (-not $LocalInstance) {
            $Ui.SimpleLocalActionButton.Content = Get-LocalizedUiText 'CONFIGURER' 'SET UP'
            $Ui.SimpleLocalActionButton.IsEnabled = $true
        }
        elseif (-not $ServerInstalled) {
            $Ui.SimpleLocalActionButton.Content = Get-LocalizedUiText 'INSTALLER' 'INSTALL'
            $Ui.SimpleLocalActionButton.IsEnabled = (-not $Running -and -not $UpdateBusy)
        }
        elseif ($LocalProcess) {
            $Ui.SimpleLocalActionButton.Content = Get-LocalizedUiText 'OUVRIR RUST' 'OPEN RUST'
            $Ui.SimpleLocalActionButton.IsEnabled = $true
        }
        else {
            $Ui.SimpleLocalActionButton.Content = Get-LocalizedUiText 'DÉMARRER' 'START'
            $Ui.SimpleLocalActionButton.IsEnabled = [bool]($LocalInstance -and (-not $Running -or [bool]$Catalog.allowMultiInstance) -and -not $UpdateBusy)
        }
        $Ui.SimpleFriendsActionButton.IsEnabled = [bool](@($Catalog.instances | Where-Object { [bool]$_.isPublic }).Count)
        $Ui.DashLocalButton.Visibility = if ($SelectedProcess) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
        $Ui.DashStopButton.Visibility = if ($SelectedProcess) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        foreach ($Button in @($Ui.ApplyMapButton,$Ui.GenerateMapButton,$Ui.CreateBackupButton,$Ui.MapWipeButton,$Ui.FullWipeButton,$Ui.RestoreBackupButton)) {
            $Button.IsEnabled = -not $Running
        }

        $DisplayedCommand = Get-SelectedConnectCommand
        if ($CapturePath -and $Selected -and [bool]$Selected.isPublic) {
            # Les captures de documentation utilisent l'adresse TEST-NET-3 afin
            # de ne jamais publier l'IPv4 réelle de l'hôte.
            $DisplayedCommand = "client.connect 203.0.113.10:$($Selected.serverPort)"
        }
        if ($Selected) {
            $Ui.DashboardServerNameText.Text = [string]$Selected.displayName
            $Ui.DashboardServerAddressText.Text = ($DisplayedCommand -replace '^client\.connect\s+','')
            $Ui.SimpleServerNameText.Text = [string]$Selected.displayName
            $Ui.SimpleServerAddressText.Text = ($DisplayedCommand -replace '^client\.connect\s+','')
            $Ui.SimpleServerStateText.Text = if ($SelectedProcess) { 'ACTIF' } else { 'ARRÊTÉ' }
            $Ui.SimpleServerStateText.Foreground = $BrushConverter.ConvertFromString($(if ($SelectedProcess) { '#72D79B' } else { '#D65332' }))
        }
        if ($Selected -and -not [bool]$Selected.isPublic) {
            $Ui.SideConnectionTitleText.Text = 'CONNEXION LOCALE'
            $Ui.SideAddressUpdatedText.Text = if ($SelectedProcess) { "$($Selected.displayName) actif" } else { "$($Selected.displayName) sélectionné" }
        }
        else {
            $Ui.SideConnectionTitleText.Text = 'CONNEXION AMIS'
            if ($script:PublicIpTask -and -not $script:PublicIpTask.IsCompleted) {
                $Ui.SideAddressUpdatedText.Text = 'Recherche de l''adresse publique...'
            }
            elseif ($script:FriendCommandCheckedAt -gt [datetime]::MinValue) {
                $Ui.SideAddressUpdatedText.Text = 'MAJ auto ' + $script:FriendCommandCheckedAt.ToString('HH:mm:ss')
            }
            else {
                $Ui.SideAddressUpdatedText.Text = 'Adresse lue dans CONNEXION-AMIS.txt'
            }
        }
        $Ui.SideAddressText.Text = $DisplayedCommand
        Update-BoxCorrelation $Selected $SelectedProcess
        $Ui.DashAddressText.Text = $DisplayedCommand
        if ($Selected) {
            $Ui.InstanceGamePortText.Text = "UDP $($Selected.serverPort)"
            $Ui.InstanceQueryPortText.Text = "UDP $($Selected.queryPort)"
            $Ui.InstanceRconPortText.Text = "127.0.0.1:$($Selected.rconPort)"
        }
    }
    catch {
        Set-Activity ('Etat du serveur indisponible : ' + $_.Exception.Message)
    }
}

function Update-ModeInspector {
    $Capability = $Ui.ModeCapabilityGrid.SelectedItem
    if (-not $Capability) {
        $Ui.ModeInspectorTitleText.Text = 'SÉLECTIONNE UN MODE'
        $Ui.ModeInspectorPluginText.Text = '—'
        $Ui.ModeInspectorConfigText.Text = '—'
        $Ui.ModeInspectorStateText.Text = '—'
        $Ui.ModeOpenConfigButton.IsEnabled = $false
        $Ui.ModeReloadPluginButton.IsEnabled = $false
        return
    }
    $Ui.ModeInspectorTitleText.Text = ([string]$Capability.DisplayName).ToUpperInvariant()
    $Ui.ModeInspectorPluginText.Text = [string]$Capability.PluginFile
    $Ui.ModeInspectorConfigText.Text = [string]$Capability.ConfigName
    $Ui.ModeInspectorStateText.Text = [string]$Capability.RuntimeState
    $Ui.ModeOpenConfigButton.IsEnabled = Test-Path -LiteralPath ([string]$Capability.ConfigPath)
    $Ui.ModeReloadPluginButton.IsEnabled = [bool]$Capability.Enabled
}

function Refresh-PluginCapabilities([object[]]$Plugins) {
    if ($null -eq $Plugins) { $Plugins = @(Get-DisplayedPlugins) }
    # Une copie archivée dans disabled-plugins reste gérable dans Extensions,
    # mais ne doit ni compter deux fois ni débloquer une interface de mode.
    $Plugins = @($Plugins | Where-Object { [string]$_.Etat -eq 'Actif' })
    $Environment = Get-DisplayedEnvironment
    $Capabilities = @(Get-RustPluginCapabilities -ServerRoot $ServerRoot -Plugins @($Plugins))
    if (-not $Environment.Installed) {
        foreach ($Capability in $Capabilities) {
            $Capability.Enabled = $false
            $Capability.RuntimeState = 'Framework de mods requis'
        }
    }
    $script:DetectedPlugins = @($Plugins)
    $script:ModeCapabilities = @($Capabilities)

    $ModesVisible = $Capabilities.Count -gt 0
    if ($ModesVisible) { [void]$script:SubTabHidden.Remove(5) } else { [void]$script:SubTabHidden.Add(5) }
    if (-not $ModesVisible -and [int]$Ui.MainTabs.SelectedIndex -eq 5 -and $script:InterfaceMode -eq 'advanced') {
        Select-AdvancedNav -Tab 4
    }
    Update-SubNav
    $Ui.ModesTabItem.Visibility = if ($ModesVisible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.ModeEnvironmentText.Text = [string]$Environment.Label
    $Ui.ModePluginCountText.Text = [string]$Plugins.Count
    $Ui.ModeCapabilityCountText.Text = [string]$Capabilities.Count

    $SelectedId = if ($Ui.ModeCapabilityGrid.SelectedItem) { [string]$Ui.ModeCapabilityGrid.SelectedItem.Id } else { '' }
    $Ui.ModeCapabilityGrid.ItemsSource = $null
    $Ui.ModeCapabilityGrid.ItemsSource = @($Capabilities)
    $SelectedCapability = @($Capabilities | Where-Object Id -eq $SelectedId) | Select-Object -First 1
    if (-not $SelectedCapability) {
        $SelectedCapability = @($Capabilities | Where-Object { Test-Path -LiteralPath ([string]$_.ConfigPath) }) | Select-Object -First 1
    }
    if (-not $SelectedCapability) { $SelectedCapability = @($Capabilities) | Select-Object -First 1 }
    if ($SelectedCapability) { $Ui.ModeCapabilityGrid.SelectedItem = $SelectedCapability }

    $PanelMap = [ordered]@{
        competitive  = @('ModeLobbyPanel','ModeCompetitivePanel')
        progression  = @('ModeProgressionPanel')
        gungame      = @('ModeGunGamePanel')
        towerdefense = @('ModeTowerDefensePanel')
        duel         = @('ModeDuelPanel')
        training     = @('ModeTrainingPanel')
    }
    foreach ($Entry in $PanelMap.GetEnumerator()) {
        $Capability = @($Capabilities | Where-Object Id -eq $Entry.Key) | Select-Object -First 1
        foreach ($ControlName in @($Entry.Value)) {
            $Ui[$ControlName].Visibility = if ($Capability) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
            $Ui[$ControlName].IsEnabled = [bool]($Capability -and $Capability.Enabled)
        }
    }

    $DuelCapability = @($Capabilities | Where-Object Id -eq 'duel') | Select-Object -First 1
    $ProgressionCapability = @($Capabilities | Where-Object Id -eq 'progression') | Select-Object -First 1
    $CompetitiveCapability = @($Capabilities | Where-Object Id -eq 'competitive') | Select-Object -First 1
    $Ui.DuelRewardsGroup.Visibility = if ($DuelCapability) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.ProgressionRewardsGroup.Visibility = if ($ProgressionCapability) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.CompetitiveRewardsGroup.Visibility = if ($CompetitiveCapability) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.ModeRewardsPanel.Visibility = if ($DuelCapability -or $ProgressionCapability -or $CompetitiveCapability) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }

    $KnownPluginNames = @(Get-RustPluginCapabilityRegistry | Select-Object -ExpandProperty Plugin)
    $UnknownCount = @($Plugins | Where-Object FileBase -notin $KnownPluginNames).Count
    $Ui.ModeUnknownNoteText.Text = if ($UnknownCount -gt 0) {
        "$UnknownCount plugin(s) sans interface de mode restent entièrement gérables dans Extensions."
    } else {
        'Un plugin inconnu reste gérable dans Extensions sans créer de page de mode automatique.'
    }
    Update-ModeInspector
}

# ----- Vue d'ensemble : etat en direct et console ----------------------------

function Write-DashConsole([string]$Command, [string]$Response) {
    $Stamp = (Get-Date).ToString('HH:mm:ss')
    $Existing = [string]$Ui.DashConsoleOutput.Text
    $Entry = "[$Stamp] > $Command`r`n$Response`r`n"
    # Le plus recent en haut : on lit une console d'administration du haut vers
    # le bas, sans avoir a faire defiler.
    $Ui.DashConsoleOutput.Text = ($Entry + $Existing).TrimEnd()
    $Ui.DashConsoleOutput.ScrollToHome()
}

function Invoke-DashConsoleCommand([string]$Command) {
    if (-not $Command) { throw 'Saisis une commande.' }
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Response = Invoke-BusyAction { Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command $Command -TimeoutMs 15000 }
    Write-DashConsole $Command ([string]$Response)
    Set-Activity "Commande envoyee : $Command"
}

function Set-DashboardLiveUnavailable([string]$Detail = '') {
    $State = Get-RustRpgServerState -ServerRoot $ServerRoot
    foreach ($Name in 'DashPlayersText','DashUptimeText','DashFpsText','DashEntitiesText') { $Ui[$Name].Text = '-' }
    $Process = @($State.Processes | Where-Object ProcessId -eq $State.ProcessId) | Select-Object -First 1
    $Ui.DashMemoryText.Text = if ($Process) { "$($Process.MemoryMb) Mo" } else { '-' }
    $Ui.DashPlayerGrid.ItemsSource = $null
    $Ui.DashPlayerSummaryText.Text = if ($State.Running) {
        'Serveur actif. Donnees en direct temporairement indisponibles ; nouvelle tentative automatique.'
    } else { 'Serveur arrete.' }
    if ($Detail) { Write-Debug ("Dashboard RCON : " + $Detail) }
}

function Refresh-DashboardLive([string]$JsonOverride = '', [switch]$FromWorker) {
    $State = Get-RustRpgServerState -ServerRoot $ServerRoot
    if (-not $State.Running) {
        foreach ($Name in 'DashPlayersText','DashUptimeText','DashFpsText','DashEntitiesText') { $Ui[$Name].Text = '-' }
        $Ui.DashMemoryText.Text = '-'
        $Ui.DashPlayerGrid.ItemsSource = $null
        $Ui.DashPlayerSummaryText.Text = 'Serveur arrete.'
        return
    }

    # L'actualisation automatique ne doit jamais immobiliser WPF pendant un
    # demarrage ou une micro-coupure RCON. Une seule requete silencieuse peut etre
    # en vol ou en attente ; les ticks de cinq secondes suivants sont ignores.
    if (-not $FromWorker -and -not $CapturePath) {
        $PendingDashboard = [bool]($script:ActiveServerOperation -and $script:ActiveServerOperation.Operation -eq 'dashboard')
        if (-not $PendingDashboard) {
            $PendingDashboard = @($script:ServerOperationQueue.ToArray() | Where-Object Operation -eq 'dashboard').Count -gt 0
        }
        if (-not $PendingDashboard) {
            Queue-ServerOperation -Operation dashboard -Label 'actualisation du direct' -TimeoutMs 2500 -Silent -OnSuccess {
                param($Json)
                Refresh-DashboardLive -JsonOverride $Json -FromWorker
            } -OnError {
                param($Message)
                Set-DashboardLiveUnavailable -Detail $Message
            }
        }
        return
    }

    if ($FromWorker) {
        try { $Payload = $JsonOverride | ConvertFrom-Json }
        catch { Set-DashboardLiveUnavailable -Detail $_.Exception.Message; return }
        if (-not $Payload -or -not [bool]$Payload.running) { Set-DashboardLiveUnavailable; return }
        $Info = $Payload.info
        $Players = @($Payload.players)
    }
    else {
        # Mode capture/QA : l'appel reste synchrone afin que l'image contienne les
        # valeurs finales avant la fermeture automatique de la fenetre.
        try {
            $Info = Get-RustRpgServerInfo -ServerRoot $ServerRoot -RconPort ([int]$State.RconPort)
            $Players = @(Get-RustRpgPlayers -ServerRoot $ServerRoot -RconPort ([int]$State.RconPort))
        }
        catch { Set-DashboardLiveUnavailable -Detail $_.Exception.GetBaseException().Message; return }
    }

    # serverinfo repond en JSON : joueurs, uptime, images par seconde, memoire et
    # nombre d'entites en un seul aller-retour.
    if ($Info) {
        $Ui.DashPlayersText.Text = "$($Info.Players)/$($Info.MaxPlayers)"
        $Ui.DashUptimeText.Text = Format-RustRpgDuration ([int]$Info.Uptime)
        $Ui.DashFpsText.Text = [string][int]$Info.Framerate
        $Ui.DashMemoryText.Text = "$($Info.Memory) Mo"
        $Ui.DashEntitiesText.Text = [string]$Info.EntityCount
    }

    $Ui.DashPlayerGrid.ItemsSource = $null
    $Ui.DashPlayerGrid.ItemsSource = $Players
    $Ui.DashPlayerSummaryText.Text = if ($Players.Count -eq 0) { 'Personne connecte pour le moment.' } else { "$($Players.Count) joueur(s) en jeu." }
}

function Restart-RustServerFromDashboard {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    if (-not (Confirm-Disruption 'Redemarrer le serveur')) { Set-Activity 'Redemarrage annule.'; return }

    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Id = [string]$Catalog.selectedId
    $null = Send-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'quit'
    Set-Activity 'Arret demande. Le serveur sera relance des que le processus aura rendu la main.'

    # On attend la fin du processus avant de relancer : demarrer trop tot echoue
    # sur le verrou de fichiers du monde.
    $Deadline = (Get-Date).AddSeconds(180)
    $Timer = New-Object Windows.Threading.DispatcherTimer
    $Timer.Interval = [TimeSpan]::FromSeconds(5)
    $Timer.Add_Tick({
        if ((Get-RustRpgServerState).Running) {
            if ((Get-Date) -gt $Deadline) {
                $Timer.Stop()
                Set-Activity "Redemarrage abandonne : le serveur ne s'est pas arrete a temps."
            }
            return
        }
        $Timer.Stop()
        Invoke-UiAction { Start-RustInstance -Id $Id; Set-Activity 'Serveur relance.' }
    })
    $Timer.Start()
}

function Refresh-DashboardMetrics {
    $Plugins = @(Get-DisplayedPlugins)
    $Environment = Get-DisplayedEnvironment
    $Backups = @(Get-RustServerBackups -ServerRoot $ServerRoot)
    $ActiveCount = @($Plugins | Where-Object Etat -eq 'Actif').Count
    $Ui.DashPluginCountText.Text = [string]$ActiveCount
    $Ui.DashBackupCountText.Text = [string]$Backups.Count
    $ServerExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
    $ServerVersion = if (Test-Path -LiteralPath $ServerExe) { [string](Get-Item -LiteralPath $ServerExe).VersionInfo.FileVersion } else { 'non installé' }
    $Ui.DashRustVersionText.Text = $ServerVersion
    $Ui.DashboardEnvironmentText.Text = [string]$Environment.Label
    $Ui.SimpleEnvironmentText.Text = [string]$Environment.Label
    $CapabilityCount = @($script:ModeCapabilities).Count
    if (-not $Environment.Installed) {
        $Ui.DashboardEnvironmentTitleText.Text = 'Serveur vanilla prêt'
        $Ui.DashboardEnvironmentDescriptionText.Text = 'Installe Carbon ou Oxide/uMod puis ajoute des plugins pour débloquer des extensions et des modes de jeu.'
        $Ui.DashboardEnvironmentNoticeBorder.BorderBrush = $BrushConverter.ConvertFromString('#8D6131')
    }
    elseif ($CapabilityCount -eq 0) {
        $Ui.DashboardEnvironmentTitleText.Text = "$($Environment.Label) détecté, aucun mode installé"
        $Ui.DashboardEnvironmentDescriptionText.Text = 'Le serveur reste proche du vanilla. Importe des plugins : leurs fonctions compatibles apparaîtront automatiquement.'
        $Ui.DashboardEnvironmentNoticeBorder.BorderBrush = $BrushConverter.ConvertFromString('#5A5047')
    }
    else {
        $Ui.DashboardEnvironmentTitleText.Text = "$CapabilityCount capacité(s) de jeu détectée(s)"
        $Ui.DashboardEnvironmentDescriptionText.Text = "La page Modes de jeu est disponible et n'affiche que les réglages fournis par les plugins installés."
        $Ui.DashboardEnvironmentNoticeBorder.BorderBrush = $BrushConverter.ConvertFromString('#416B4E')
    }
    $EnvironmentDetail = if ($Environment.Installed) { "$($Environment.Label) $($Environment.Version)".Trim() } else { 'VANILLA' }
    $ModeSuffix=if($script:CurrentUiLanguage-eq'en-US'){"$CapabilityCount MODE(S) DETECTED"}else{"$CapabilityCount MODE(S) DÉTECTÉ(S)"}
    $Ui.FooterVersionText.Text = "SERVER CONTROL CENTER v12.1.0  |  RUST $ServerVersion  |  $EnvironmentDetail  |  $ModeSuffix"
}

function Start-RustServer([ValidateSet('local','online')][string]$Mode) {
    $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
    $Instance = if ($Mode -eq 'online') { @($Catalog.instances | Where-Object isPublic) | Select-Object -First 1 } else { @($Catalog.instances | Where-Object { -not [bool]$_.isPublic }) | Select-Object -First 1 }
    if (-not $Instance) { throw "Aucune instance '$Mode' n'est configurée." }
    Start-RustInstance -Id ([string]$Instance.id)
}

function Stop-RustServer {
    Stop-SelectedInstance
}

function Get-RustClientWindow {
    return @(Get-Process -Name 'RustClient' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 -and $_.Responding } |
        Sort-Object StartTime -Descending) | Select-Object -First 1
}

function Send-RustConsoleCommand([Parameter(Mandatory = $true)][string]$Command) {
    $RustClient = Get-RustClientWindow
    if (-not $RustClient) { return $false }

    # Le clic vient de notre fenêtre, Windows autorise donc normalement le passage
    # au premier plan. Echap ferme d'abord chat/menu/console, puis F1 garantit une
    # console ouverte avant de coller la commande.
    $Handle = [IntPtr]$RustClient.MainWindowHandle
    $null = [RustControlCenter.NativeWindow]::ShowWindowAsync($Handle,9)
    Start-Sleep -Milliseconds 120
    $null = [RustControlCenter.NativeWindow]::SetForegroundWindow($Handle)
    Start-Sleep -Milliseconds 180
    [Windows.Clipboard]::SetText($Command)
    [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
    Start-Sleep -Milliseconds 100
    [System.Windows.Forms.SendKeys]::SendWait('{F1}')
    Start-Sleep -Milliseconds 250
    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 80
    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
    return $true
}

function Complete-PendingRustJoin {
    if (-not $script:PendingRustJoinCommand) { return }
    if ((Get-Date) -gt $script:PendingRustJoinDeadline) {
        $RustJoinTimer.Stop()
        $Command = $script:PendingRustJoinCommand
        $script:PendingRustJoinCommand = ''
        [Windows.Clipboard]::SetText($Command)
        Set-Activity "Rust n'a pas répondu à temps. La commande est copiée : ouvre F1 puis fais Ctrl+V et Entrée."
        return
    }
    if (Send-RustConsoleCommand -Command $script:PendingRustJoinCommand) {
        $Command = $script:PendingRustJoinCommand
        $script:PendingRustJoinCommand = ''
        $RustJoinTimer.Stop()
        Set-Activity "Commande envoyée dans Rust : $Command"
    }
}

function Join-RustServer {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { throw 'Sélectionne une instance.' }
    $Address = "127.0.0.1:$($Instance.serverPort)"
    # La commande client actuelle documentée par Facepunch est `connect`.
    # `client.connect` a été utilisé historiquement mais n'est plus fiable selon
    # la version du client Rust.
    $Command = "connect $Address"
    [Windows.Clipboard]::SetText($Command)

    if (Send-RustConsoleCommand -Command $Command) {
        Set-Activity "Commande envoyée dans Rust : $Command"
        return
    }

    $script:PendingRustJoinCommand = $Command
    $script:PendingRustJoinDeadline = (Get-Date).AddMinutes(5)
    $RustJoinTimer.Start()
    $SteamExe = 'C:\Program Files (x86)\Steam\steam.exe'
    if (Test-Path -LiteralPath $SteamExe) {
        Start-Process -FilePath $SteamExe -ArgumentList @('-applaunch','252490','+connect',$Address)
    }
    else { Start-Process 'steam://rungameid/252490' }
    Set-Activity "Rust démarre. La connexion à $Address sera envoyée automatiquement dès que sa fenêtre sera prête."
}

function Copy-FriendAddress {
    [Windows.Clipboard]::SetText($Ui.SideAddressText.Text)
    Set-Activity "Adresse copiee dans le presse-papiers."
}

function Load-ServerSettings {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { return }
    $Cfg = Get-RustServerCfg -ServerRoot $ServerRoot -Identity ([string]$Instance.identity)
    $Ui.HostnameBox.Text = [string]$Cfg['server.hostname']
    $Ui.DescriptionBox.Text = [string]$Cfg['server.description']
    $Ui.MaxPlayersBox.Text = [string]$Cfg['server.maxplayers']
    $Ui.SaveIntervalBox.Text = [string]$Cfg['server.saveinterval']
    $Ui.PveCheck.IsChecked = ([string]$Cfg['server.pve'] -eq 'true')
    $Ui.CreativeCheck.IsChecked = ([string]$Cfg['creative.allusers'] -eq 'true')
}

function Save-ServerSettings {
    $Instance = Get-SelectedServerInstance
    if (-not $Instance) { throw 'Sélectionne une instance.' }
    $MaxPlayers = 0
    $SaveInterval = 0
    if (-not [int]::TryParse($Ui.MaxPlayersBox.Text,[ref]$MaxPlayers) -or $MaxPlayers -lt 1 -or $MaxPlayers -gt 500) { throw 'Joueurs max : valeur attendue entre 1 et 500.' }
    if (-not [int]::TryParse($Ui.SaveIntervalBox.Text,[ref]$SaveInterval) -or $SaveInterval -lt 30 -or $SaveInterval -gt 3600) { throw 'Intervalle de sauvegarde : valeur attendue entre 30 et 3600 secondes.' }
    $Values = @{
        'server.hostname' = $Ui.HostnameBox.Text.Trim()
        'server.description' = $Ui.DescriptionBox.Text.Trim()
        'server.maxplayers' = $MaxPlayers
        'server.saveinterval' = $SaveInterval
        'server.pve' = ([bool]$Ui.PveCheck.IsChecked).ToString().ToLowerInvariant()
        'server.radiation' = 'true'
        'server.globalchat' = 'true'
        'creative.allusers' = ([bool]$Ui.CreativeCheck.IsChecked).ToString().ToLowerInvariant()
    }
    $Backup = Set-RustServerCfg -ServerRoot $ServerRoot -Values $Values -Identity ([string]$Instance.identity)
    Set-Activity "Configuration serveur enregistree. Copie : $Backup"
}

function Load-MapProfile {
    $Identity = Get-SelectedText $Ui.MapIdentityCombo
    if (-not $Identity) { return }
    $Profile = Get-RustMapProfile -ServerRoot $ServerRoot -Identity $Identity
    $Ui.MapTypeCombo.SelectedValue = $Profile.Type
    $Ui.MapSeedBox.Text = [string]$Profile.Seed
    $Ui.MapSizeCombo.SelectedItem = $Profile.WorldSize
    $Ui.MapUrlBox.Text = $Profile.LevelUrl
    $Ui.MapUrlBox.IsEnabled = ($Profile.Type -eq 'Custom URL')
    $Ui.MapCurrentText.Text = "$($Profile.DisplayName)`nType : $($Profile.Type)`nSeed : $($Profile.Seed)`nTaille : $($Profile.WorldSize)m" + $(if($Profile.LevelUrl){"`nURL : $($Profile.LevelUrl)"}else{''})
}

function Save-MapProfile {
    $Seed = 0L
    $Size = 0
    if (-not [long]::TryParse($Ui.MapSeedBox.Text,[ref]$Seed)) { throw 'Seed invalide.' }
    if (-not [int]::TryParse([string]$Ui.MapSizeCombo.SelectedItem,[ref]$Size)) { throw 'Taille de carte invalide.' }
    $Profile = Set-RustMapProfile -ServerRoot $ServerRoot -Identity (Get-SelectedText $Ui.MapIdentityCombo) -Type (Get-SelectedText $Ui.MapTypeCombo) -Seed $Seed -WorldSize $Size -LevelUrl $Ui.MapUrlBox.Text.Trim()
    Load-MapProfile
    Set-Activity "Profil de carte $($Profile.Identity) enregistre."
    return $Profile
}

function Refresh-MapLibrary {
    $SelectedId = if ($Ui.MapLibraryGrid.SelectedItem) { [string]$Ui.MapLibraryGrid.SelectedItem.Id } else { '' }
    $Store = Get-RustMapLibrary -ServerRoot $ServerRoot
    $Rows = @($Store.maps | ForEach-Object {
        [pscustomobject]@{Id=[string]$_.id;Name=[string]$_.name;Size=Format-RustByteSize ([long]$_.sizeBytes);Hash=([string]$_.sha256).Substring(0,[math]::Min(16,([string]$_.sha256).Length)) + '…';PublicState=if([string]$_.publicUrl){'CONFIGURÉE'}else{'LOCALE'};Raw=$_}
    })
    $Ui.MapLibraryGrid.ItemsSource = $null
    $Ui.MapLibraryGrid.ItemsSource = $Rows
    $Ui.MapLibrarySummaryText.Text = "$($Rows.Count) carte(s) RustEdit importée(s), vérifiée(s) par SHA-256."
    $Selection = @($Rows | Where-Object Id -eq $SelectedId) | Select-Object -First 1
    if (-not $Selection) { $Selection = @($Rows) | Select-Object -First 1 }
    if ($Selection) { $Ui.MapLibraryGrid.SelectedItem = $Selection }
    Update-MapLibraryInspector
}

function Update-MapLibraryInspector {
    $Row = $Ui.MapLibraryGrid.SelectedItem
    if (-not $Row) {
        $Ui.MapLibraryDetailText.Text = 'Sélectionne une carte importée.'
        $Ui.MapLibraryPublicUrlBox.Text = ''
        $Ui.ApplyImportedMapButton.IsEnabled = $false
        $Ui.SaveMapLibraryUrlButton.IsEnabled = $false
        return
    }
    $Map = $Row.Raw
    $Ui.MapLibraryPublicUrlBox.Text = [string]$Map.publicUrl
    $Ui.MapLibraryDetailText.Text = "$($Map.name)`n$([string]$Map.path)`nSHA-256 : $($Map.sha256)"
    $Ui.ApplyImportedMapButton.IsEnabled = $true
    $Ui.SaveMapLibraryUrlButton.IsEnabled = $true
}

function Import-RustEditMapFromDialog {
    if ($CapturePath) { throw 'Import désactivé pendant une capture.' }
    $Dialog = New-Object Microsoft.Win32.OpenFileDialog
    $Dialog.Title = 'Importer une carte RustEdit'
    $Dialog.Filter = 'Carte RustEdit (*.map)|*.map'
    if (-not $Dialog.ShowDialog($Window)) { return }
    $Map = Import-RustEditMap -ServerRoot $ServerRoot -SourcePath $Dialog.FileName
    Refresh-MapLibrary
    $Ui.MapLibraryGrid.SelectedItem = @($Ui.MapLibraryGrid.ItemsSource | Where-Object Id -eq ([string]$Map.id)) | Select-Object -First 1
    Update-MapLibraryInspector
    Set-Activity "Carte RustEdit importée et vérifiée : $($Map.name)."
}

function Save-SelectedMapPublicUrl {
    $Row = $Ui.MapLibraryGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une carte RustEdit.' }
    $null = Set-RustEditMapPublicUrl -ServerRoot $ServerRoot -MapId ([string]$Row.Id) -PublicUrl $Ui.MapLibraryPublicUrlBox.Text.Trim()
    Refresh-MapLibrary
    Set-Activity 'URL publique de la carte enregistrée.'
}

function Apply-SelectedImportedMap {
    $Row = $Ui.MapLibraryGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une carte RustEdit.' }
    $Identity = Get-SelectedText $Ui.MapIdentityCombo
    if (-not (Confirm-Action "Appliquer la carte '$($Row.Name)' au serveur $Identity ?`n`nLe monde actuel ne sera effacé que si tu utilises ensuite le bouton de génération." 'Appliquer une carte RustEdit')) { return }
    $Profile = Set-RustInstanceImportedMap -ServerRoot $ServerRoot -Identity $Identity -MapId ([string]$Row.Id)
    Load-MapProfile
    Set-Activity "Carte RustEdit appliquée au profil $($Profile.DisplayName)."
}

function Get-ArenaProfileDefinitions {
    return @(
        [pscustomobject]@{Id='gungame';Mode='Gun Game';Plugin='RustGunGame';Template='Arène FFA';Spawns='12 auto';GenerateCommand='ggarena.random';CleanupCommand='gg.stop';Templates=@([pscustomobject]@{Code='random';Label='FFA · couvertures aléatoires'})},
        [pscustomobject]@{Id='duel';Mode='Duel';Plugin='RustDuel';Template='1v1 à 4v4';Spawns='8 auto';GenerateCommand='duel.arena.preview';CleanupCommand='duel.stop';Templates=@([pscustomobject]@{Code='random';Label='Aléatoire'},[pscustomobject]@{Code='cercle';Label='Cercle'},[pscustomobject]@{Code='symetrique';Label='Symétrique'},[pscustomobject]@{Code='ouverte';Label='Ouverte'})},
        [pscustomobject]@{Id='zombie';Mode='Zombie';Plugin='RustRPG';Template='Vagues / Endless';Spawns='Survivants auto';GenerateCommand='zombie.force';CleanupCommand='zombie.stop';Templates=@([pscustomobject]@{Code='normal';Label='Survie classique'},[pscustomobject]@{Code='endless';Label='Survie Endless'})},
        [pscustomobject]@{Id='towerdefense';Mode='Tower Defense';Plugin='RustTowerDefense';Template='Deux voies fixes';Spawns='Auto';GenerateCommand='td.validate';CleanupCommand='td.stop';Templates=@([pscustomobject]@{Code='normal';Label='Deux voies · normal'},[pscustomobject]@{Code='endless';Label='Deux voies · Endless'})}
    )
}

function Refresh-ArenaProfiles {
    $SelectedId = if ($Ui.ArenaProfileGrid.SelectedItem) { [string]$Ui.ArenaProfileGrid.SelectedItem.Id } else { '' }
    $Plugins = @(Get-DisplayedPlugins | Where-Object Etat -eq 'Actif')
    $Rows = foreach ($Definition in @(Get-ArenaProfileDefinitions)) {
        if (-not @($Plugins | Where-Object FileBase -eq $Definition.Plugin).Count) { continue }
        [pscustomobject]@{Id=$Definition.Id;Mode=$Definition.Mode;Plugin=$Definition.Plugin;Template=$Definition.Template;Spawns=$Definition.Spawns;State='PRÊT';Raw=$Definition}
    }
    $Ui.ArenaProfileGrid.ItemsSource = $null
    $Ui.ArenaProfileGrid.ItemsSource = @($Rows)
    $Ui.ArenaSummaryText.Text = if (@($Rows).Count) { "$(@($Rows).Count) générateur(s) disponible(s) grâce aux plugins actifs." } else { 'Aucun plugin Gun Game, Zombie, Duel ou Tower Defense actif : les générateurs restent masqués.' }
    $Selection = @($Rows | Where-Object Id -eq $SelectedId) | Select-Object -First 1
    if (-not $Selection) { $Selection = @($Rows) | Select-Object -First 1 }
    if ($Selection) { $Ui.ArenaProfileGrid.SelectedItem = $Selection }
    $Ui.ArenaLocationCombo.ItemsSource = @('Aléatoire sûr')
    $Ui.ArenaLocationCombo.SelectedIndex = 0
    Update-ArenaProfileEditor
}

function Update-ArenaProfileEditor {
    $Row = $Ui.ArenaProfileGrid.SelectedItem
    $Ui.ArenaTemplateCombo.ItemsSource = $null
    if (-not $Row) { $Ui.GenerateArenaButton.IsEnabled=$false;$Ui.CleanupArenaButton.IsEnabled=$false;return }
    $Ui.ArenaTemplateCombo.DisplayMemberPath = 'Label'
    $Ui.ArenaTemplateCombo.SelectedValuePath = 'Code'
    $Ui.ArenaTemplateCombo.ItemsSource = @($Row.Raw.Templates)
    $Ui.ArenaTemplateCombo.SelectedIndex = 0
    $Running = (Get-RustRpgServerState).Running
    $Ui.GenerateArenaButton.IsEnabled = [bool]$Running
    $Ui.CleanupArenaButton.IsEnabled = [bool]$Running
}

function Generate-SelectedArena {
    $Row = $Ui.ArenaProfileGrid.SelectedItem
    if (-not $Row) { throw 'Aucun générateur de plugin actif.' }
    if (-not (Get-RustRpgServerState).Running) { throw 'Démarre le serveur avant de générer une arène.' }
    $Template = [string]$Ui.ArenaTemplateCombo.SelectedValue
    $Command = [string]$Row.Raw.GenerateCommand
    switch ([string]$Row.Id) {
        'duel' {
            $PreviewTemplate = if ($Template -eq 'random') { @('cercle','symetrique','ouverte') | Get-Random } else { $Template }
            $Command = "duel.arena.preview $PreviewTemplate 30"
        }
        'zombie' { $Command = if ($Template -eq 'endless') { 'zombie.endless' } else { 'zombie.force' } }
        'towerdefense' { $Command = if ($Template -eq 'endless') { 'td.validate endless' } else { 'td.validate' } }
    }
    Queue-ServerOperation -Operation command -Command $Command -Label ("génération arène " + [string]$Row.Mode) -OnSuccess { param($Response) Set-Activity ([string]$Response) }
}

function Cleanup-SelectedArena {
    $Row = $Ui.ArenaProfileGrid.SelectedItem
    if (-not $Row) { throw 'Aucune arène sélectionnée.' }
    if (-not (Confirm-Action "Nettoyer l’arène $($Row.Mode) et arrêter ce mode ?" 'Nettoyer une arène')) { return }
    Queue-ServerOperation -Operation command -Command ([string]$Row.Raw.CleanupCommand) -Label ("nettoyage arène " + [string]$Row.Mode) -OnSuccess { param($Response) Set-Activity ([string]$Response) }
}

function Invoke-TrackedMapGeneration([string]$Identity) {
    if (-not $Identity) { throw 'Identité de carte manquante.' }
    $Metadata = [pscustomobject]@{ identity=$Identity }
    return Invoke-TrackedSynchronousAction -Type MapGenerate -Title ("Préparation de la carte " + $Identity) -ServerId $Identity -Stage 'SAUVEGARDE & NETTOYAGE' -Detail 'La carte actuelle est sauvegardée puis les fichiers de monde sont préparés pour la prochaine génération.' -RetryAction 'map-generate' -Metadata $Metadata -Action {
        Invoke-RustServerWipe -ServerRoot $ServerRoot -Identity $Identity -Type map -CleanGeneratedMaps
    }
}

function Invoke-TrackedWipe {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][ValidateSet('map','full')][string]$Type,
        [bool]$ResetPluginData = $false,
        [bool]$CleanGeneratedMaps = $false
    )
    $Title = if ($Type -eq 'full') { "Wipe complet de $Identity" } else { "Wipe carte de $Identity" }
    $Metadata = [pscustomobject]@{ identity=$Identity; wipeType=$Type; resetPluginData=$ResetPluginData; cleanGeneratedMaps=$CleanGeneratedMaps }
    return Invoke-TrackedSynchronousAction -Type Wipe -Title $Title -ServerId $Identity -Stage 'SAUVEGARDE & WIPE' -Detail 'Une sauvegarde complète est créée avant toute suppression.' -RetryAction 'wipe' -Metadata $Metadata -Action {
        Invoke-RustServerWipe -ServerRoot $ServerRoot -Identity $Identity -Type $Type -ResetPluginData:$ResetPluginData -CleanGeneratedMaps:$CleanGeneratedMaps
    }
}

function Generate-NewMap {
    if (-not (Confirm-Action "Le monde cible sera sauvegarde puis sa sauvegarde de carte sera effacee. Rust generera la nouvelle carte au prochain lancement.`n`nContinuer ?" 'Generer une nouvelle carte')) { return }
    $Profile = Save-MapProfile
    $Result = Invoke-TrackedMapGeneration -Identity $Profile.Identity
    Refresh-Backups
    Refresh-DashboardMetrics
    Show-Info "Nouvelle carte preparee.`n`nFichiers retires : $($Result.DeletedFiles)`nSauvegarde : $($Result.BackupPath)`n`nLance maintenant le serveur cible."
}

function Refresh-Backups {
    $Items = @(Get-RustServerBackups -ServerRoot $ServerRoot)
    $Ui.BackupGrid.ItemsSource = $null
    $Ui.BackupGrid.ItemsSource = $Items
    $Ui.DashBackupCountText.Text = [string]$Items.Count
}

function Create-ManualBackup {
    $Identity = Get-SelectedText $Ui.WipeIdentityCombo
    Set-Activity "Sauvegarde de $Identity en cours..."
    $Path = Invoke-TrackedSynchronousAction -Type Backup -Title ("Sauvegarde de " + $Identity) -ServerId $Identity -Stage 'COPIE DES DONNÉES' -Detail 'Les données du serveur sont copiées vers le dossier de sauvegardes.' -Action {
        New-RustServerBackup -ServerRoot $ServerRoot -Identity $Identity
    }
    Refresh-Backups
    Set-Activity "Sauvegarde terminee : $Path"
}

function Verify-SelectedBackup {
    $Item = $Ui.BackupGrid.SelectedItem
    if (-not $Item) { throw 'Selectionne une sauvegarde.' }
    Set-Activity 'Vérification SHA256 de la sauvegarde...'
    $Check = Test-RustServerBackup -ServerRoot $ServerRoot -BackupPath ([string]$Item.Path)
    Refresh-Backups
    if (-not $Check.Valid) { throw 'Sauvegarde invalide : ' + $Check.Detail }
    Set-Activity $Check.Detail
    Show-Info ("Sauvegarde valide.`n`nIntégrité : {0}`n{1}" -f $Check.Integrity,$Check.Detail)
}

function Run-ManualWipe([ValidateSet('map','full')][string]$Type) {
    $Identity = Get-SelectedText $Ui.WipeIdentityCombo
    $Description = if ($Type -eq 'full') { 'la carte ET les blueprints' } else { 'la carte, en conservant les blueprints' }
    if (-not (Confirm-Action "Cette operation va effacer $Description pour $Identity.`nUne sauvegarde complete sera creee avant le wipe.`n`nContinuer ?" 'Confirmer le wipe')) { return }
    Set-Activity "Wipe $Type de $Identity en cours..."
    $Result = Invoke-TrackedWipe -Identity $Identity -Type $Type -ResetPluginData ([bool]$Ui.ResetPluginDataCheck.IsChecked) -CleanGeneratedMaps ([bool]$Ui.CleanMapsCheck.IsChecked)
    Refresh-Backups
    Refresh-DashboardMetrics
    Show-Info "Wipe termine.`nFichiers retires : $($Result.DeletedFiles)`nSauvegarde : $($Result.BackupPath)"
}

function Restore-SelectedBackup {
    $Item = $Ui.BackupGrid.SelectedItem
    if (-not $Item) { throw 'Selectionne une sauvegarde.' }
    if (-not (Confirm-Action "Restaurer la sauvegarde du $($Item.Date) pour $($Item.Identity) ?`nL'etat actuel sera lui aussi sauvegarde avant restauration." 'Restaurer une sauvegarde')) { return }
    Set-Activity 'Restauration en cours...'
    $Identity = Restore-RustServerBackup -ServerRoot $ServerRoot -BackupPath $Item.Path
    Refresh-Backups
    Set-Activity "Sauvegarde restauree pour $Identity."
}

function Get-MaintenanceActionLabel([string]$Action) {
    switch ($Action) {
        'Backup' { return 'Sauvegarde' }
        'FullWipe' { return 'Full wipe' }
        default { return 'Wipe carte' }
    }
}

function Get-MaintenanceDayLabel([string]$Day) {
    $Labels = @{ Monday='lundi'; Tuesday='mardi'; Wednesday='mercredi'; Thursday='jeudi'; Friday='vendredi'; Saturday='samedi'; Sunday='dimanche' }
    if ($Labels.ContainsKey($Day)) { return $Labels[$Day] }
    return $Day
}

function Get-MaintenanceCadenceLabel($Schedule) {
    switch ([string]$Schedule.recurrence) {
        'Daily' { return 'Chaque jour à ' + [string]$Schedule.localTime }
        'Weekly' { return (Get-MaintenanceDayLabel ([string]$Schedule.dayOfWeek)) + ' à ' + [string]$Schedule.localTime }
        default { return 'Toutes les ' + [string]$Schedule.intervalHours + ' h' }
    }
}

function Get-MaintenanceStatusLabel([string]$Status) {
    switch ($Status) {
        'Succeeded' { return 'RÉUSSIE' }
        'Deferred' { return 'REPORTÉE' }
        'Failed' { return 'ÉCHEC' }
        default { return 'JAMAIS EXÉCUTÉE' }
    }
}

function Get-MaintenanceDisplayRows {
    $Schedules = @((Get-RustMaintenanceScheduleStore -ServerRoot $ServerRoot).schedules)
    if ($CapturePath -and $CaptureScheduleDemo) {
        $Now = [datetime]::UtcNow
        $Schedules = @(
            [pscustomobject]@{ id='capture-weekly'; name='Wipe hebdomadaire'; identity='serveur-amis'; action='MapWipe'; recurrence='Weekly'; localTime='04:00'; dayOfWeek='Thursday'; intervalHours=24; enabled=$true; stopAndRestart=$true; resetPluginData=$false; cleanGeneratedMaps=$true; nextRunUtc=$Now.AddDays(2).ToString('o'); lastRunUtc=$Now.AddDays(-5).ToString('o'); lastStatus='Succeeded'; lastDetail='Sauvegarde créée et wipe terminé.' },
            [pscustomobject]@{ id='capture-backup'; name='Sauvegarde quotidienne'; identity='serveur-local'; action='Backup'; recurrence='Daily'; localTime='03:30'; dayOfWeek='Monday'; intervalHours=24; enabled=$true; stopAndRestart=$false; resetPluginData=$false; cleanGeneratedMaps=$false; nextRunUtc=$Now.AddHours(8).ToString('o'); lastRunUtc=$Now.AddHours(-16).ToString('o'); lastStatus='Succeeded'; lastDetail='Sauvegarde terminée.' },
            [pscustomobject]@{ id='capture-monthly'; name='Full wipe mensuel'; identity='serveur-amis'; action='FullWipe'; recurrence='Interval'; localTime='04:00'; dayOfWeek='Thursday'; intervalHours=720; enabled=$false; stopAndRestart=$true; resetPluginData=$true; cleanGeneratedMaps=$true; nextRunUtc=$Now.AddDays(21).ToString('o'); lastRunUtc=''; lastStatus='Never'; lastDetail='' }
        )
    }
    $Instances = @(Get-RustServerInstances -ServerRoot $ServerRoot)
    return @($Schedules | Sort-Object @{Expression={-not [bool]$_.enabled}},nextRunUtc | ForEach-Object {
        $Schedule = $_
        $Instance = @($Instances | Where-Object identity -eq ([string]$Schedule.identity)) | Select-Object -First 1
        $Next = '-'
        try { $Next = [datetime]::Parse([string]$Schedule.nextRunUtc).ToLocalTime().ToString('dd/MM/yyyy HH:mm') } catch {}
        [pscustomobject]@{
            Id         = [string]$Schedule.id
            Name       = [string]$Schedule.name
            Server     = if($Instance){[string]$Instance.displayName}else{[string]$Schedule.identity}
            Action     = Get-MaintenanceActionLabel ([string]$Schedule.action)
            Cadence    = Get-MaintenanceCadenceLabel $Schedule
            NextRun    = $Next
            LastStatus = Get-MaintenanceStatusLabel ([string]$Schedule.lastStatus)
            State      = if([bool]$Schedule.enabled){'ACTIVE'}else{'PAUSE'}
            Raw        = $Schedule
        }
    })
}

function Update-MaintenanceWorkerStatus {
    if ($CapturePath -and $CaptureScheduleDemo) {
        $Ui.MaintenanceWorkerStatusText.Text = 'ACTIF · CHAQUE MINUTE'
        $Ui.MaintenanceWorkerStatusText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
        $Ui.InstallMaintenanceWorkerButton.IsEnabled = $false
        $Ui.RemoveMaintenanceWorkerButton.IsEnabled = $true
        return
    }
    $Status = Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot
    if ($Status.Installed) {
        $Ui.MaintenanceWorkerStatusText.Text = 'ACTIF · CHAQUE MINUTE'
        $Ui.MaintenanceWorkerStatusText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
        $Ui.InstallMaintenanceWorkerButton.IsEnabled = $false
        $Ui.RemoveMaintenanceWorkerButton.IsEnabled = $true
    }
    else {
        $Ui.MaintenanceWorkerStatusText.Text = 'APP OUVERTE UNIQUEMENT'
        $Ui.MaintenanceWorkerStatusText.Foreground = $BrushConverter.ConvertFromString('#EFA45D')
        $Ui.InstallMaintenanceWorkerButton.IsEnabled = $true
        $Ui.RemoveMaintenanceWorkerButton.IsEnabled = $false
    }
}

function Refresh-MaintenanceSchedules([string]$SelectId = '') {
    $WantedId = if ($SelectId) { $SelectId } elseif ($script:SelectedScheduleId) { $script:SelectedScheduleId } else { '' }
    $Rows = @(Get-MaintenanceDisplayRows)
    $Ui.ScheduleGrid.ItemsSource = $null
    $Ui.ScheduleGrid.ItemsSource = $Rows
    $EnabledCount = @($Rows | Where-Object State -eq 'ACTIVE').Count
    $NextRow = @($Rows | Where-Object State -eq 'ACTIVE' | Sort-Object NextRun) | Select-Object -First 1
    $Ui.MaintenanceSummaryText.Text = if (-not $Rows.Count) { 'Aucune règle enregistrée. Crée une sauvegarde ou un wipe récurrent ci-dessous.' } elseif ($NextRow) { "$EnabledCount règle(s) active(s) sur $($Rows.Count) · prochaine : $($NextRow.NextRun)" } else { "$($Rows.Count) règle(s) enregistrée(s) · toutes en pause" }
    $Selected = @($Rows | Where-Object Id -eq $WantedId) | Select-Object -First 1
    if ($Selected) {
        $Ui.ScheduleGrid.SelectedItem = $Selected
        Load-MaintenanceScheduleEditor -Schedule $Selected.Raw
    }
    elseif (-not $script:MaintenanceEditorInitialized) { New-MaintenanceScheduleEditor }
    Update-MaintenanceWorkerStatus
}

function New-MaintenanceScheduleEditor {
    $script:MaintenanceEditorInitialized = $true
    $script:MaintenanceEditorLoading = $true
    $script:SelectedScheduleId = ''
    $Ui.ScheduleGrid.SelectedItem = $null
    $Ui.ScheduleEditorTitleText.Text = 'NOUVELLE RÈGLE'
    $Ui.ScheduleNameBox.Text = 'Maintenance hebdomadaire'
    if ($Ui.ScheduleIdentityCombo.Items.Count -gt 0) { $Ui.ScheduleIdentityCombo.SelectedIndex = 0 }
    $Ui.ScheduleActionCombo.SelectedValue = 'Backup'
    $Ui.ScheduleRecurrenceCombo.SelectedValue = 'Weekly'
    $Ui.ScheduleTimeBox.Text = '04:00'
    $Ui.ScheduleDayCombo.SelectedValue = 'Thursday'
    $Ui.ScheduleIntervalBox.Text = '24'
    $Ui.ScheduleRetentionBox.Text = '10'
    $Ui.ScheduleEnabledCheck.IsChecked = $true
    $Ui.ScheduleStopRestartCheck.IsChecked = $false
    $Ui.ScheduleResetPluginDataCheck.IsChecked = $false
    $Ui.ScheduleCleanMapsCheck.IsChecked = $true
    $script:MaintenanceEditorLoading = $false
    $script:MaintenanceEditorDirty = $false
    Update-MaintenanceEditorState
}

function Load-MaintenanceScheduleEditor($Schedule) {
    if (-not $Schedule) { return }
    $script:MaintenanceEditorInitialized = $true
    $script:MaintenanceEditorLoading = $true
    $script:SelectedScheduleId = [string]$Schedule.id
    $Ui.ScheduleEditorTitleText.Text = 'MODIFIER LA RÈGLE'
    $Ui.ScheduleNameBox.Text = [string]$Schedule.name
    $Ui.ScheduleIdentityCombo.SelectedValue = [string]$Schedule.identity
    $Ui.ScheduleActionCombo.SelectedValue = [string]$Schedule.action
    $Ui.ScheduleRecurrenceCombo.SelectedValue = [string]$Schedule.recurrence
    $Ui.ScheduleTimeBox.Text = [string]$Schedule.localTime
    $Ui.ScheduleDayCombo.SelectedValue = [string]$Schedule.dayOfWeek
    $Ui.ScheduleIntervalBox.Text = [string]$Schedule.intervalHours
    $Ui.ScheduleRetentionBox.Text = if ($Schedule.PSObject.Properties.Name -contains 'retentionCount') { [string]$Schedule.retentionCount } else { '10' }
    $Ui.ScheduleEnabledCheck.IsChecked = [bool]$Schedule.enabled
    $Ui.ScheduleStopRestartCheck.IsChecked = [bool]$Schedule.stopAndRestart
    $Ui.ScheduleResetPluginDataCheck.IsChecked = [bool]$Schedule.resetPluginData
    $Ui.ScheduleCleanMapsCheck.IsChecked = [bool]$Schedule.cleanGeneratedMaps
    $script:MaintenanceEditorLoading = $false
    $script:MaintenanceEditorDirty = $false
    Update-MaintenanceEditorState
}

function Set-MaintenanceEditorDirty {
    if (-not $script:MaintenanceEditorLoading -and $script:MaintenanceEditorInitialized) { $script:MaintenanceEditorDirty = $true }
}

function Update-MaintenanceEditorState {
    $Recurrence = Get-SelectedText $Ui.ScheduleRecurrenceCombo
    $Action = Get-SelectedText $Ui.ScheduleActionCombo
    $IsWipe = $Action -in @('MapWipe','FullWipe')
    $Ui.ScheduleTimeBox.IsEnabled = ($Recurrence -ne 'Interval')
    $Ui.ScheduleDayCombo.IsEnabled = ($Recurrence -eq 'Weekly')
    $Ui.ScheduleIntervalBox.IsEnabled = ($Recurrence -eq 'Interval')
    $Ui.ScheduleStopRestartCheck.IsEnabled = $IsWipe
    $Ui.ScheduleResetPluginDataCheck.IsEnabled = $IsWipe
    $Ui.ScheduleCleanMapsCheck.IsEnabled = $IsWipe
    try {
        $Interval = 24
        [int]::TryParse($Ui.ScheduleIntervalBox.Text,[ref]$Interval) | Out-Null
        $Next = Get-RustMaintenanceNextRunUtc -Recurrence $Recurrence -LocalTime $Ui.ScheduleTimeBox.Text.Trim() -DayOfWeek (Get-SelectedText $Ui.ScheduleDayCombo) -IntervalHours $Interval
        $Ui.ScheduleNextRunText.Text = 'Prochaine exécution : ' + $Next.ToLocalTime().ToString('dddd dd/MM/yyyy à HH:mm',[Globalization.CultureInfo]::GetCultureInfo('fr-FR'))
    }
    catch { $Ui.ScheduleNextRunText.Text = 'Corrige les paramètres pour calculer la prochaine exécution.' }
}

function Save-MaintenanceScheduleEditor {
    if ($CapturePath) { throw 'La capture de documentation ne peut pas modifier le planning.' }
    $Interval = 0
    if (-not [int]::TryParse($Ui.ScheduleIntervalBox.Text.Trim(),[ref]$Interval)) { throw "L'intervalle doit etre un nombre d'heures." }
    $Retention = 0
    if (-not [int]::TryParse($Ui.ScheduleRetentionBox.Text.Trim(),[ref]$Retention) -or $Retention -lt 2 -or $Retention -gt 100) { throw 'La rotation doit conserver entre 2 et 100 sauvegardes.' }
    $Schedule = Set-RustMaintenanceSchedule -ServerRoot $ServerRoot -Id $script:SelectedScheduleId -Name $Ui.ScheduleNameBox.Text.Trim() -Identity (Get-SelectedText $Ui.ScheduleIdentityCombo) -Action (Get-SelectedText $Ui.ScheduleActionCombo) -Recurrence (Get-SelectedText $Ui.ScheduleRecurrenceCombo) -LocalTime $Ui.ScheduleTimeBox.Text.Trim() -DayOfWeek (Get-SelectedText $Ui.ScheduleDayCombo) -IntervalHours $Interval -RetentionCount $Retention -Enabled ([bool]$Ui.ScheduleEnabledCheck.IsChecked) -StopAndRestart ([bool]$Ui.ScheduleStopRestartCheck.IsChecked) -ResetPluginData ([bool]$Ui.ScheduleResetPluginDataCheck.IsChecked) -CleanGeneratedMaps ([bool]$Ui.ScheduleCleanMapsCheck.IsChecked)
    $script:SelectedScheduleId = [string]$Schedule.id
    $script:MaintenanceEditorDirty = $false
    Refresh-MaintenanceSchedules -SelectId $script:SelectedScheduleId
    Set-Activity "Règle '$($Schedule.name)' enregistrée."
}

function Toggle-SelectedMaintenanceSchedule {
    $Row = $Ui.ScheduleGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une règle.' }
    if ($CapturePath) { throw 'La capture de documentation ne peut pas modifier le planning.' }
    $Enabled = -not [bool]$Row.Raw.enabled
    $null = Set-RustMaintenanceScheduleEnabled -ServerRoot $ServerRoot -Id ([string]$Row.Id) -Enabled $Enabled
    Refresh-MaintenanceSchedules -SelectId ([string]$Row.Id)
    Set-Activity $(if($Enabled){'Règle activée.'}else{'Règle mise en pause.'})
}

function Delete-SelectedMaintenanceSchedule {
    $Row = $Ui.ScheduleGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une règle.' }
    if ($CapturePath) { throw 'La capture de documentation ne peut pas modifier le planning.' }
    if (-not (Confirm-Action "Supprimer la règle '$($Row.Name)' ?`nAucune sauvegarde existante ne sera effacée." 'Supprimer la règle')) { return }
    $null = Remove-RustMaintenanceSchedule -ServerRoot $ServerRoot -Id ([string]$Row.Id)
    New-MaintenanceScheduleEditor
    Refresh-MaintenanceSchedules
    Set-Activity 'Règle supprimée. Les sauvegardes existantes sont conservées.'
}

function Start-MaintenanceWorker([string]$ScheduleId = '',[switch]$Force) {
    $WorkerPath = Join-Path $ServerRoot 'tool\RustRPG-MaintenanceWorker.ps1'
    if (-not (Test-Path -LiteralPath $WorkerPath)) { throw 'Le moteur de maintenance est introuvable.' }
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"' + $WorkerPath + '"'),'-ServerRoot',('"' + $ServerRoot + '"'))
    if ($ScheduleId) { $Arguments += @('-ScheduleId',$ScheduleId) }
    if ($Force) { $Arguments += '-Force' }
    Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden | Out-Null
    $script:MaintenanceWorkerLastLaunch = Get-Date
}

function Run-SelectedMaintenanceSchedule {
    $Row = $Ui.ScheduleGrid.SelectedItem
    if (-not $Row) { throw 'Sélectionne une règle.' }
    if ($CapturePath) { throw 'La capture de documentation ne peut pas exécuter une maintenance.' }
    $Warning = if ([string]$Row.Raw.action -eq 'Backup') { 'Créer cette sauvegarde maintenant ?' } else { "Exécuter ce wipe maintenant ?`nUne sauvegarde obligatoire sera créée. Si le serveur est actif, les garde-fous de la règle restent appliqués." }
    if (-not (Confirm-Action $Warning 'Exécuter la règle')) { return }
    Start-MaintenanceWorker -ScheduleId ([string]$Row.Id) -Force
    Set-Activity "Maintenance '$($Row.Name)' lancée silencieusement. Suis-la dans Opérations."
}

function Install-MaintenanceWorkerTask {
    if (-not (Confirm-Action "Activer la vérification Windows chaque minute ?`n`nLes règles continueront ainsi à fonctionner quand le Control Center est fermé, tant que ta session Windows est ouverte." 'Activer le service de maintenance')) { return }
    $null = Register-RustMaintenanceTask -ServerRoot $ServerRoot
    Update-MaintenanceWorkerStatus
    Set-Activity 'Service de maintenance activé dans le Planificateur de tâches Windows.'
}

function Remove-MaintenanceWorkerTask {
    if (-not (Confirm-Action "Désactiver le service en arrière-plan ?`nLes règles resteront enregistrées et fonctionneront encore lorsque l'application est ouverte." 'Désactiver le service')) { return }
    $null = Unregister-RustMaintenanceTask -ServerRoot $ServerRoot
    Update-MaintenanceWorkerStatus
    Set-Activity 'Service en arrière-plan désactivé. Les règles sont conservées.'
}

function Start-DueMaintenanceWorker {
    if ($CapturePath -or ((Get-Date) - $script:MaintenanceWorkerLastLaunch).TotalSeconds -lt 20) { return }
    if (@(Get-RustDueMaintenanceSchedules -ServerRoot $ServerRoot).Count -gt 0) { Start-MaintenanceWorker }
}

# ----- Taux et multiplicateurs ----------------------------------------------
# Les lignes par ressource sont construites en code plutot qu'avec un
# DataTemplate : un PSCustomObject n'implemente pas INotifyPropertyChanged, donc
# une liaison bidirectionnelle sur un curseur ne remonterait pas les valeurs. On
# garde ici une reference directe sur chaque curseur.

$script:RateSliders = @{}

function Test-RustRatesAvailable {
    return Test-RustPluginActive 'RustRates'
}

function Get-RustRatesState {
    if (-not (Test-RustRatesAvailable)) { return $null }
    if (-not (Get-RustRpgServerState).Running) { return $null }
    try {
        $Raw = [string](Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'rates.json' -TimeoutMs 12000)
        if (-not $Raw.TrimStart().StartsWith('{')) { return $null }
        return $Raw | ConvertFrom-Json
    }
    catch { return $null }
}

function Set-RustRate([string]$Key, [string]$Value) {
    $null = Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command "rates.set $Key $Value" -TimeoutMs 20000
}

function Refresh-Rates {
    $Available = Test-RustRatesAvailable
    $Running = (Get-RustRpgServerState).Running

    # Le sous-onglet reste toujours visible. Avant, l'entree n'etait revelee que
    # par cette fonction -- appelee uniquement depuis la page qu'elle masquait --
    # et n'apparaissait donc jamais. La page affiche elle-meme l'avertissement
    # quand RustRates n'est pas actif.

    if (-not $Available) {
        $Ui.RatesNoticeText.Text = "Le plugin RustRates n'est pas actif. Rust n'a aucun multiplicateur de recolte natif : sans ce plugin, aucun taux ne peut etre applique. Active-le dans Mods & Modes."
        $script:RateSliders = @{}
        $Ui.RatesResourceList.Children.Clear()
        return
    }
    if (-not $Running) {
        $Ui.RatesNoticeText.Text = 'Serveur arrete : demarre-le pour lire et modifier les taux.'
        return
    }

    $State = Invoke-BusyAction { Get-RustRatesState }
    if (-not $State) {
        $Ui.RatesNoticeText.Text = 'RustRates est actif mais ne repond pas. Recharge le plugin puis actualise.'
        return
    }

    $Ui.RatesNoticeText.Text = "RustRates actif. Multiplicateur global x$($State.global). Les valeurs ci-dessous refletent la configuration du serveur."
    $Ui.RatesGlobalBox.Text = [string]$State.global
    $Ui.RatesGatherCheck.IsChecked = [bool]$State.recolte
    $Ui.RatesPickupCheck.IsChecked = [bool]$State.ramassage
    $Ui.RatesStackCheck.IsChecked = [bool]$State.piles
    $Ui.RatesStackBox.Text = [string]$State.pilesX
    $Ui.RatesCraftCheck.IsChecked = [bool]$State.fabrication
    $Ui.RatesCraftBox.Text = [string]$State.fabricationX
    $Ui.RatesSmeltCheck.IsChecked = [bool]$State.fonte
    $Ui.RatesSmeltBox.Text = [string]$State.fonteX

    Build-RateResourceRows $State
}

function Build-RateResourceRows($State) {
    $Ui.RatesResourceList.Children.Clear()
    $script:RateSliders = @{}
    if (-not $State.ressources) { return }

    foreach ($Property in @($State.ressources.PSObject.Properties | Sort-Object Name)) {
        $Row = New-Object Windows.Controls.Grid
        $Row.Margin = '0,0,0,6'
        $NameColumn = New-Object Windows.Controls.ColumnDefinition
        $NameColumn.Width = New-Object Windows.GridLength 190
        $SliderColumn = New-Object Windows.Controls.ColumnDefinition
        $SliderColumn.Width = New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star)
        $ValueColumn = New-Object Windows.Controls.ColumnDefinition
        $ValueColumn.Width = New-Object Windows.GridLength 70
        $Row.ColumnDefinitions.Add($NameColumn)
        $Row.ColumnDefinitions.Add($SliderColumn)
        $Row.ColumnDefinitions.Add($ValueColumn)

        $Label = New-Object Windows.Controls.TextBlock
        $Label.Text = $Property.Name
        $Label.Foreground = $BrushConverter.ConvertFromString('#EDE4D5')
        $Label.VerticalAlignment = 'Center'
        [Windows.Controls.Grid]::SetColumn($Label, 0)
        $null = $Row.Children.Add($Label)

        $Slider = New-Object Windows.Controls.Slider
        $Slider.Minimum = 0
        $Slider.Maximum = 20
        $Slider.TickFrequency = 0.5
        $Slider.IsSnapToTickEnabled = $true
        $Slider.Value = [double]$Property.Value
        $Slider.VerticalAlignment = 'Center'
        $Slider.Margin = '10,0'
        [Windows.Controls.Grid]::SetColumn($Slider, 1)
        $null = $Row.Children.Add($Slider)

        $Value = New-Object Windows.Controls.TextBlock
        $Value.VerticalAlignment = 'Center'
        $Value.Foreground = $BrushConverter.ConvertFromString('#9FD36F')
        $Value.Text = Format-RateValue ([double]$Property.Value)
        [Windows.Controls.Grid]::SetColumn($Value, 2)
        $null = $Row.Children.Add($Value)

        # Chaque curseur met a jour son propre libelle, capture par valeur.
        $Slider.Add_ValueChanged({
            param($SenderObject, $EventArgs)
            $Target = $SenderObject.Tag
            if ($Target) { $Target.Text = Format-RateValue $SenderObject.Value }
        })
        $Slider.Tag = $Value

        $script:RateSliders[$Property.Name] = $Slider
        $null = $Ui.RatesResourceList.Children.Add($Row)
    }
}

function Format-RateValue([double]$Value) {
    if ($Value -le 0) { return 'global' }
    return 'x' + $Value.ToString('0.##')
}

function Apply-RateGlobal([string]$Value) {
    if (-not (Test-RustRatesAvailable)) { throw "RustRates n'est pas actif." }
    $Parsed = 0.0
    if (-not [double]::TryParse(($Value -replace ',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -or $Parsed -le 0) {
        throw 'Multiplicateur invalide : indique un nombre superieur a zero.'
    }
    Invoke-BusyAction { Set-RustRate 'global' ($Parsed.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    Refresh-Rates
    Set-Activity "Multiplicateur global applique : x$Parsed."
}

function Apply-RateDomains {
    if (-not (Test-RustRatesAvailable)) { throw "RustRates n'est pas actif." }
    Invoke-BusyAction {
        Set-RustRate 'recolte' ($(if ($Ui.RatesGatherCheck.IsChecked) { 'true' } else { 'false' }))
        Set-RustRate 'ramassage' ($(if ($Ui.RatesPickupCheck.IsChecked) { 'true' } else { 'false' }))
        foreach ($Entry in @(
            @{ Box = $Ui.RatesStackBox; Key = 'piles'; Toggle = 'activerpiles'; Checked = $Ui.RatesStackCheck.IsChecked },
            @{ Box = $Ui.RatesCraftBox; Key = 'fabrication'; Toggle = 'activerfabrication'; Checked = $Ui.RatesCraftCheck.IsChecked },
            @{ Box = $Ui.RatesSmeltBox; Key = 'fonte'; Toggle = 'activerfonte'; Checked = $Ui.RatesSmeltCheck.IsChecked }
        )) {
            $Parsed = 0.0
            if ([double]::TryParse(($Entry.Box.Text -replace ',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$Parsed) -and $Parsed -gt 0) {
                Set-RustRate $Entry.Key ($Parsed.ToString([Globalization.CultureInfo]::InvariantCulture))
            }
            Set-RustRate $Entry.Toggle ($(if ($Entry.Checked) { 'true' } else { 'false' }))
        }
    }
    Refresh-Rates
    Set-Activity 'Domaines appliques.'
}

function Apply-RateResources {
    if (-not (Test-RustRatesAvailable)) { throw "RustRates n'est pas actif." }
    if ($script:RateSliders.Count -eq 0) { throw 'Aucune ressource chargee.' }
    $Applied = 0
    Invoke-BusyAction {
        foreach ($Name in $script:RateSliders.Keys) {
            $Value = [math]::Round($script:RateSliders[$Name].Value, 2)
            Set-RustRate $Name ($Value.ToString([Globalization.CultureInfo]::InvariantCulture))
            $Applied++
        }
    }
    Refresh-Rates
    Set-Activity "$Applied ressource(s) appliquee(s)."
}

function Reset-RateResources {
    foreach ($Name in $script:RateSliders.Keys) { $script:RateSliders[$Name].Value = 0 }
    Set-Activity 'Toutes les ressources sont revenues sur le multiplicateur global. Clique sur APPLIQUER pour enregistrer.'
}

# ----- Vue simple : Mes serveurs --------------------------------------------
# La page Serveurs avancee gere l'edition fine des instances. Ici on ne montre
# que ce dont un debutant a besoin : quels serveurs existent, lequel tourne, et
# le bouton qui change cet etat.

function Test-ControlCenterUpdateRunning {
    return [bool]($script:UpdateOperation -and [string]$script:UpdateOperation.State -eq 'Running')
}

function Show-ControlCenterUpdateProgress {
    $Operation = $script:UpdateOperation
    if (-not $Operation) {
        $Ui.SimpleServersProgressPanel.Visibility = [Windows.Visibility]::Collapsed
        return
    }

    $Ui.SimpleServersProgressPanel.Visibility = [Windows.Visibility]::Visible
    $Ui.SimpleServersProgressStage.Text = [string]$Operation.Stage
    $Ui.SimpleServersProgressPercent.Text = ('{0} %' -f [math]::Round([double]$Operation.Percent))
    $Ui.SimpleServersProgressBar.Value = [math]::Max([double]0,[math]::Min([double]100,[double]$Operation.Percent))
    $Ui.SimpleServersProgressDetail.Text = [string]$Operation.Detail

    switch ([string]$Operation.State) {
        'Completed' {
            $Ui.SimpleServersProgressBar.Foreground = $BrushConverter.ConvertFromString('#72D79B')
            $Ui.SimpleServersProgressPercent.Foreground = $BrushConverter.ConvertFromString('#9FD36F')
        }
        'Failed' {
            $Ui.SimpleServersProgressBar.Foreground = $BrushConverter.ConvertFromString('#C74738')
            $Ui.SimpleServersProgressPercent.Foreground = $BrushConverter.ConvertFromString('#E76A4C')
            $Ui.SimpleServersProgressPercent.Text = 'ÉCHEC'
        }
        default {
            $Ui.SimpleServersProgressBar.Foreground = $BrushConverter.ConvertFromString('#D65332')
            $Ui.SimpleServersProgressPercent.Foreground = $BrushConverter.ConvertFromString('#EFA45D')
            $Ui.SimpleServersInstallButton.IsEnabled = $false
            $Ui.SimpleServersInstallButton.Content = if (Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe')) { 'MISE À JOUR...' } else { 'INSTALLATION...' }
        }
    }
}

function Update-ControlCenterUpdateProgress {
    $Operation = $script:UpdateOperation
    if (-not $Operation -or [string]$Operation.State -ne 'Running') {
        Show-ControlCenterUpdateProgress
        return
    }

    $ProcessExited = $false
    $ExitCode = $null
    try {
        $Operation.Process.Refresh()
        $ProcessExited = [bool]$Operation.Process.HasExited
        if ($ProcessExited) {
            # Garantit que les flux redirigés sont entièrement écrits avant
            # d'interpréter le marqueur terminal du journal.
            $Operation.Process.WaitForExit()
            $ExitCode = [int]$Operation.Process.ExitCode
        }
    }
    catch { }

    $Lines = @()
    foreach ($LogPath in @([string]$Operation.OutputPath,[string]$Operation.ErrorPath)) {
        if ($LogPath -and (Test-Path -LiteralPath $LogPath)) {
            $Lines += @(Get-Content -LiteralPath $LogPath -Tail 180 -Encoding UTF8 -ErrorAction SilentlyContinue)
        }
    }

    $TerminalSuccess = $false
    foreach ($Line in $Lines) {
        if ([string]$Line -match 'RCC_PROGRESS\|(\d+)\|([^|]+)\|(.*)$') {
            $MarkerPercent = [double]$Matches[1]
            $Operation.Percent = [math]::Max([double]$Operation.Percent,$MarkerPercent)
            $Operation.Stage = ([string]$Matches[2]).Trim()
            $Operation.Detail = ([string]$Matches[3]).Trim()
            if ($MarkerPercent -ge 100 -and [string]$Operation.Stage -eq 'TERMINE') { $TerminalSuccess = $true }
            continue
        }
        if ([string]$Line -match 'progress:\s*([0-9]+(?:[\.,][0-9]+)?)') {
            $SteamPercent = [double](([string]$Matches[1]) -replace ',','.')
            $OverallPercent = 18 + (0.68 * [math]::Max([double]0,[math]::Min([double]100,$SteamPercent)))
            $Operation.Percent = [math]::Max([double]$Operation.Percent,$OverallPercent)
            $Operation.Stage = 'RUST DEDICATED'
            $Operation.Detail = ('SteamCMD télécharge et vérifie les fichiers Rust ({0} %).' -f [math]::Round($SteamPercent))
        }
    }

    if ([double]$Operation.Percent -lt 100) {
        # SteamCMD peut rester silencieux pendant une validation. Une avance
        # lente garde l'interface vivante sans franchir la prochaine étape.
        [double]$Cap = if ($Operation.Percent -lt 8) { 7.0 } elseif ($Operation.Percent -lt 18) { 17.0 } elseif ($Operation.Percent -lt 86) { 84.0 } elseif ($Operation.Percent -lt 94) { 93.0 } else { 99.0 }
        $script:UpdateProgressPulse++
        if (($script:UpdateProgressPulse % 2) -eq 0 -and [double]$Operation.Percent -lt $Cap) {
            $Operation.Percent = [math]::Min([double]$Cap,([double]$Operation.Percent + 0.6))
        }
    }

    if ($ProcessExited) {
        $ServerExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
        # Le marqueur TERMINE n'est écrit qu'après la validation de
        # RustDedicated.exe. Il est plus fiable que le code hérité de
        # SteamCMD par powershell.exe sur certaines configurations Windows.
        $Successful = ($TerminalSuccess -or $ExitCode -eq 0) -and (Test-Path -LiteralPath $ServerExe)
        if ($Successful) {
            $Operation.State = 'Completed'
            $Operation.Percent = 100
            $Operation.Stage = 'TERMINÉ'
            $Operation.Detail = 'Rust Dedicated est à jour. Tu peux maintenant démarrer ton serveur.'
            Set-Activity 'Mise à jour terminée : Rust Dedicated est prêt.'
        }
        else {
            $Operation.State = 'Failed'
            $Operation.Percent = [math]::Min([double]95,[math]::Max([double]5,[double]$Operation.Percent))
            $Operation.Stage = 'ÉCHEC DE LA MISE À JOUR'
            $CodeDetail = if ($null -ne $ExitCode) { " (code $ExitCode)" } else { '' }
            $Operation.Detail = "La mise à jour a échoué$CodeDetail. Ouvre Logs & maintenance pour consulter le journal détaillé."
            Set-Activity 'La mise à jour a échoué. Le détail est disponible dans les logs.'
            Set-OnboardingRepairState -RepairCode 'ServerUpdate' -Detail "Réessaie l’installation. Si elle échoue encore, ouvre le diagnostic associé dans Opérations."
        }
        Refresh-SimpleServers
        Refresh-DashboardMetrics
        Refresh-DashboardLive
        Update-RuntimeDisplay
    }
    Sync-ControlCenterUpdateOperation -Force:$ProcessExited
    Show-ControlCenterUpdateProgress
}

function Refresh-SimpleServers {
    $ServerExe = Join-Path $ServerRoot 'server\RustDedicated.exe'
    $Installed = Test-Path -LiteralPath $ServerExe
    $UpdateRunning = Test-ControlCenterUpdateRunning
    $AnyServerRunning = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot).Count -gt 0

    if ($Installed) {
        $Version = (Get-Item -LiteralPath $ServerExe).VersionInfo.FileVersion
        $Ui.SimpleServersNoticeTitle.Text = 'LOGICIEL SERVEUR INSTALLE'
        $Ui.SimpleServersNoticeText.Text = "Rust Dedicated est prêt$(if ($Version) { " (build $Version)" })."
        $Ui.SimpleServersInstallButton.Content = 'METTRE A JOUR'
    }
    else {
        $Ui.SimpleServersNoticeTitle.Text = 'LOGICIEL SERVEUR ABSENT'
        $Ui.SimpleServersNoticeText.Text = "Rust Dedicated n'est pas encore installé. Sans lui, aucun serveur ne peut démarrer. L'installation se fait via SteamCMD et prend plusieurs minutes."
        $Ui.SimpleServersInstallButton.Content = 'INSTALLER'
    }
    $Ui.SimpleServersInstallButton.IsEnabled = (-not $AnyServerRunning -and -not $UpdateRunning)
    Show-ControlCenterUpdateProgress

    $Catalog = $null
    try { $Catalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot } catch { }
    if (-not $Catalog) {
        $Ui.SimpleServersList.ItemsSource = $null
        $Ui.SimpleServersListLabel.Text = 'SERVEURS CONFIGURÉS  -  catalogue illisible'
        return
    }

    $Processes = @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot)
    $SelectedId = [string]$Catalog.selectedId

    $Rows = @(foreach ($Instance in $Catalog.instances) {
        $Running = @($Processes | Where-Object Identity -eq ([string]$Instance.identity)).Count -gt 0
        $Public = [bool]$Instance.isPublic
        $Selected = ([string]$Instance.id -eq $SelectedId)

        $Etat = if ($UpdateRunning) { $(if ($Installed) { 'MISE A JOUR' } else { 'INSTALLATION' }) } elseif (-not $Installed) { 'A INSTALLER' } elseif ($Running) { 'EN COURS' } else { 'ARRETE' }
        $Action = if ($UpdateRunning) { $(if ($Installed) { 'MISE A JOUR...' } else { 'INSTALLATION...' }) } elseif (-not $Installed) { 'INSTALLER' } elseif ($Running) { 'ARRETER' } else { 'DEMARRER' }

        [pscustomobject]@{
            Nom            = [string]$Instance.displayName
            Detail         = "Port du jeu UDP $($Instance.serverPort) - carte $($Instance.level) - $($Instance.worldSize)m$(if ($Selected) { '  •  serveur sélectionné' })"
            PorteeLabel    = if ($Public) { 'OUVERT AUX AMIS' } else { 'PRIVE' }
            PorteeCouleur  = if ($Public) { '#FFD479' } else { '#8C8276' }
            PorteeFond     = if ($Public) { '#3A3122' } else { '#232019' }
            EtatLabel      = $Etat
            EtatCouleur    = if ($Running) { '#9FD36F' } elseif ($UpdateRunning) { '#FFD479' } elseif ($Etat -eq 'A INSTALLER') { '#E76A4C' } else { '#8C8276' }
            EtatFond       = if ($Running) { '#24422E' } elseif ($UpdateRunning) { '#3A3122' } elseif ($Etat -eq 'A INSTALLER') { '#4B1E19' } else { '#232019' }
            BordureCouleur = if ($Selected) { '#5A3A2C' } else { '#39332C' }
            ActionLabel    = $Action
            ActionTag      = "$Action|$([string]$Instance.id)"
            ActionEnabled  = -not $UpdateRunning
            JoinTag        = "REJOINDRE|$([string]$Instance.id)"
            JoinVisible    = if ($Running) { 'Visible' } else { 'Collapsed' }
        }
    })

    $Ui.SimpleServersList.ItemsSource = $null
    $Ui.SimpleServersList.ItemsSource = $Rows
    $ActifCount = @($Rows | Where-Object EtatLabel -eq 'EN COURS').Count
    $Ui.SimpleServersListLabel.Text = "SERVEURS CONFIGURÉS  -  $($Rows.Count) au total, $ActifCount en cours"
}

function Invoke-SimpleServerAction([string]$Payload) {
    $Parts = $Payload -split '\|', 2
    if ($Parts.Count -lt 2) { return }
    $Action = $Parts[0]
    $Id = $Parts[1]

    switch ($Action) {
        'INSTALLER' { Start-ServerUpdate }
        'DEMARRER'  {
            # Selectionner avant de demarrer : l'adresse affichee et le RCON
            # doivent viser l'instance qu'on lance, pas la precedente.
            $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id $Id
            Start-RustInstance -Id $Id
        }
        'ARRETER'   {
            $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id $Id
            Stop-RustServer
        }
        'REJOINDRE' {
            $null = Set-RustSelectedInstance -ServerRoot $ServerRoot -Id $Id
            Join-RustServer
        }
    }
    Refresh-SimpleServers
}

# ----- Vue simple : Jouer avec des amis -------------------------------------
# La page Reseau & ports liste treize diagnostics techniques. Ici on les agrege
# en cinq etapes dans l'ordre ou un debutant doit les franchir, chacune avec un
# seul bouton. Aucun nouveau test : on reutilise Get-RustRpgNetworkDiagnostics.

function New-SimpleFriendStep([int]$Numero,[string]$Titre,[string]$Detail,[string]$Etat,[string]$ActionLabel,[string]$ActionId) {
    $Couleur = switch ($Etat) {
        'OK'        { '#9FD36F' }
        'A FAIRE'   { '#E76A4C' }
        default     { '#FFD479' }
    }
    $Fond = switch ($Etat) {
        'OK'        { '#24422E' }
        'A FAIRE'   { '#4B1E19' }
        default     { '#3A3122' }
    }
    return [pscustomobject]@{
        Numero        = $Numero
        Titre         = $Titre
        Detail        = $Detail
        EtatLabel     = $Etat
        EtatCouleur   = $Couleur
        EtatFond      = $Fond
        ActionLabel   = $ActionLabel
        ActionId      = $ActionId
        ActionVisible = if ($ActionLabel) { 'Visible' } else { 'Collapsed' }
    }
}

function Get-LatestFriendTestOperation {
    return @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object type -eq 'FriendTest' | Sort-Object startedUtc -Descending | Select-Object -First 1)
}

function Refresh-FriendTestPanel {
    $Operation = @(Get-LatestFriendTestOperation) | Select-Object -First 1
    if (-not $Operation) {
        $Ui.FriendTestStageText.Text = Get-LocalizedUiText 'Prêt à démarrer le serveur et à vérifier toute la connexion.' 'Ready to start the server and verify the full connection.'
        $Ui.FriendTestDetailText.Text = Get-LocalizedUiText 'Le rapport restera disponible dans le centre des opérations.' 'The report will remain available in the operation center.'
        $Ui.FriendTestProgressBar.Value = 0
        $Ui.FriendTestPercentText.Text = '0 %'
        $Ui.FriendTestStartButton.IsEnabled = $true
        $Ui.FriendTestCancelButton.Visibility = 'Collapsed'
        $Ui.FriendTestOpenReportButton.IsEnabled = $false
        return
    }
    if ([string]$Operation.status -eq 'Running' -and [int]$Operation.processId -gt 0) {
        $Worker = Get-Process -Id ([int]$Operation.processId) -ErrorAction SilentlyContinue
        if (-not $Worker -and ((Get-Date) - (Get-OperationDate ([string]$Operation.startedUtc))).TotalSeconds -gt 5) {
            $Operation = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation.id) -Status Interrupted -Stage 'INTERROMPU' -Detail "Le moteur du test ami s’est arrêté sans résultat final. Ouvre le rapport puis réessaie."
        }
    }
    $Progress = [math]::Max(0,[math]::Min(100,[double]$Operation.progress))
    $Ui.FriendTestProgressBar.Value = $Progress
    $Ui.FriendTestPercentText.Text = ('{0:0} %' -f $Progress)
    $Ui.FriendTestStageText.Text = [string]$Operation.stage
    $Ui.FriendTestDetailText.Text = [string]$Operation.detail
    $Running = [string]$Operation.status -eq 'Running'
    $Ui.FriendTestStartButton.IsEnabled = -not $Running
    $Ui.FriendTestCancelButton.Visibility = if ($Running) { 'Visible' } else { 'Collapsed' }
    $ReportPath = [string](Get-OperationMetadataValue $Operation 'reportPath' '')
    $Ui.FriendTestOpenReportButton.IsEnabled = [bool](($ReportPath -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) -or ([string]$Operation.logPath -and (Test-Path -LiteralPath ([string]$Operation.logPath) -PathType Leaf)))
}

function Start-FriendTest {
    if ($CapturePath) { throw 'Le test ami est désactivé pendant une capture.' }
    $Active = Get-RustActiveTrackedOperation -ServerRoot $ServerRoot
    if ($Active) { throw "Une opération est déjà en cours : $($Active.title). Attends sa fin ou annule-la." }
    $Public = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
    if (-not $Public.Count) { throw "Aucun serveur public n’est configuré. Ouvre Mes serveurs et marque une instance comme ouverte aux amis." }
    $Preflight = @(Invoke-BusyAction { Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot -FriendCommand (Get-FriendCommand) })
    $Firewall = @($Preflight | Where-Object Test -eq ("Pare-feu UDP " + [string]$Public[0].serverPort) | Select-Object -First 1)
    if (-not $Firewall.Count -or [string]$Firewall[0].Statut -ne 'OK') {
        if (-not (Confirm-Action "Le pare-feu Windows n’autorise pas encore les ports UDP $($Public[0].serverPort) et $($Public[0].queryPort).`n`nLe test peut les configurer. Windows affichera une demande administrateur unique. Continuer ?" 'Autoriser le serveur Rust')) { return }
        $NetworkSetup = Join-Path $ServerRoot 'Configure-OnlineAccess.ps1'
        if (-not (Test-Path -LiteralPath $NetworkSetup -PathType Leaf)) { throw 'Le configurateur du pare-feu est introuvable.' }
        $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $SetupProcess = Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$NetworkSetup+'"')) -WorkingDirectory $ServerRoot -WindowStyle Hidden -Wait -PassThru
        if ($SetupProcess.ExitCode -ne 0) { throw 'La configuration administrateur du pare-feu a été annulée ou a échoué.' }
    }
    $WorkerPath = Join-Path $PSScriptRoot 'RustRPG-FriendTestWorker.ps1'
    if (-not (Test-Path -LiteralPath $WorkerPath -PathType Leaf)) { throw 'Le moteur de test ami est introuvable.' }
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $LogRoot = Join-Path $ServerRoot 'logs';[IO.Directory]::CreateDirectory($LogRoot) | Out-Null
    $LogPath = Join-Path $LogRoot "friend-test-$Stamp.txt"
    $ReportPath = Join-Path $LogRoot "friend-test-$Stamp.json"
    $ErrorPath = Join-Path $LogRoot "friend-test-$Stamp-error.log"
    $OutputPath = Join-Path $LogRoot "friend-test-$Stamp-worker.log"
    $Tracked = New-RustTrackedOperation -ServerRoot $ServerRoot -Type FriendTest -Title ('Test ami — ' + [string]$Public[0].displayName) -ServerId ([string]$Public[0].id) -Stage 'PRÉPARATION' -Detail 'Le test va démarrer le serveur, vérifier Steam et attendre un ami.' -RetryAction 'friend-test' -CanCancel $true -LogPath $LogPath -ErrorLogPath $ErrorPath -Metadata ([pscustomobject]@{instanceId=[string]$Public[0].id;reportPath=$ReportPath})
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$WorkerPath+'"'),'-ServerRoot',('"'+$ServerRoot+'"'),'-InstanceId',([string]$Public[0].id),'-OperationId',([string]$Tracked.id))
    try {
        $Process = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath -PassThru
        $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Changes @{processId=[int]$Process.Id}
    }
    catch {
        $null = Complete-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Tracked.id) -Status Failed -Stage 'ÉCHEC' -Detail $_.Exception.Message
        throw
    }
    Refresh-OperationCenter
    Refresh-FriendTestPanel
    Set-Activity 'Test ami lancé silencieusement. La commande apparaîtra dès que le serveur sera prêt.'
}

function Request-FriendTestCancellation {
    $Operation = @(Get-RustTrackedOperations -ServerRoot $ServerRoot | Where-Object { $_.type -eq 'FriendTest' -and $_.status -eq 'Running' } | Select-Object -First 1)
    if (-not $Operation.Count) { throw 'Aucun test ami en cours.' }
    if (-not (Confirm-Action 'Annuler le test ami ? Le serveur déjà démarré restera disponible.' 'Annuler le test ami')) { return }
    $CancelPath = Join-Path $ServerRoot ("data\friend-test-cancel-$([string]$Operation[0].id).request")
    [IO.Directory]::CreateDirectory((Split-Path $CancelPath -Parent)) | Out-Null
    [IO.File]::WriteAllText($CancelPath,[datetime]::UtcNow.ToString('o'),[Text.UTF8Encoding]::new($false))
    $null = Update-RustTrackedOperation -ServerRoot $ServerRoot -Id ([string]$Operation[0].id) -Changes @{stage='ANNULATION';detail='Annulation demandée, arrêt propre du test en cours...'}
    Refresh-FriendTestPanel
}

function Open-FriendTestReport {
    $Operation = @(Get-LatestFriendTestOperation) | Select-Object -First 1
    if (-not $Operation) { throw 'Aucun rapport de test ami.' }
    $ReportPath = [string](Get-OperationMetadataValue $Operation 'reportPath' '')
    $Path = if ($ReportPath -and (Test-Path -LiteralPath $ReportPath -PathType Leaf)) { $ReportPath } else { [string]$Operation.logPath }
    $Path = Assert-OperationLogPath $Path
    Start-Process -FilePath notepad.exe -ArgumentList ('"' + $Path + '"')
}

function Refresh-SimpleFriends {
    $Items = @(Invoke-BusyAction { Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot -FriendCommand (Get-FriendCommand) })

    $State = Get-RustRpgServerState -ServerRoot $ServerRoot
    $Command = Get-FriendCommand
    if ($CapturePath) { $Command = 'client.connect 203.0.113.10:28115' }
    $Ui.SimpleFriendsAddress.Text = $Command

    $Steps = @()

    # 1. Le serveur doit tourner, et ce doit etre l'instance publique.
    $Public = @(Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1
    $GamePort = if ($Public) { [int]$Public.serverPort } else { 28115 }
    if (-not $Public) {
        $Steps += New-SimpleFriendStep 1 'Ton serveur public' "Aucun serveur ouvert aux amis n'est configuré. Il en faut un marqué public." 'A FAIRE' 'CONFIGURER' 'configure'
    }
    elseif ($State.Running) {
        $Steps += New-SimpleFriendStep 1 'Ton serveur public' "$($Public.displayName) tourne sur le port UDP $($Public.serverPort)." 'OK' '' ''
    }
    else {
        $Steps += New-SimpleFriendStep 1 'Ton serveur public' "$($Public.displayName) est configuré mais arrêté. Tes amis ne peuvent pas se connecter tant qu'il ne tourne pas." 'A FAIRE' 'DEMARRER' 'start'
    }

    # 2. Pare-feu Windows. On cible le port du jeu et lui seul : un motif large
    # attrapait aussi la regle du port de requete, qui n'est pas bloquante.
    $Firewall = @($Items | Where-Object { $_.Test -eq "Pare-feu UDP $GamePort" }) | Select-Object -First 1
    if ($Firewall -and $Firewall.Statut -eq 'OK') {
        $Steps += New-SimpleFriendStep 2 'Pare-feu Windows' "Le port du jeu est autorisé à entrer : $($Firewall.Detail)" 'OK' '' ''
    }
    else {
        $Steps += New-SimpleFriendStep 2 'Pare-feu Windows' "Aucune règle d'entrée détectée pour le port UDP $GamePort. Sans elle, personne ne peut entrer, même avec la box bien réglée." 'A FAIRE' 'OUVRIR LE PARE-FEU' 'firewall'
    }

    # 3. Box : impossible a verifier depuis Windows, on guide sans affirmer.
    $Nat = @($Items | Where-Object { $_.Test -match 'Livebox' }) | Select-Object -First 1
    $NatDetail = if ($CapturePath) { "Rediriger UDP $GamePort vers 192.0.2.10:$GamePort ; UDP $($GamePort+2) est recommandé pour les requêtes." } elseif ($Nat -and $Nat.Detail) { $Nat.Detail } else { "Rediriger le port UDP $GamePort vers ce PC." }
    $Steps += New-SimpleFriendStep 3 'Box Internet (redirection)' "$NatDetail Cette étape ne peut pas être vérifiée depuis Windows : elle se règle dans l'interface de ta box." 'A VERIFIER' 'OUVRIR MA BOX' 'router'

    # 4. Steam fournit maintenant un contrôle extérieur officiel du port query.
    $Steam = @($Items | Where-Object Test -eq 'Visibilité Steam externe') | Select-Object -First 1
    if ($Steam -and $Steam.Statut -eq 'OK') {
        $Steps += New-SimpleFriendStep 4 'Test depuis l''extérieur' ([string]$Steam.Detail) 'OK' '' ''
    } else {
        $SteamDetail = if ($Steam -and $Steam.Detail) { [string]$Steam.Detail } else { 'Steam ne confirme pas encore le serveur depuis Internet.' }
        $Steps += New-SimpleFriendStep 4 'Test depuis l''extérieur' $SteamDetail 'A VERIFIER' 'LANCER LE TEST AMI' 'friend-test'
    }

    # 5. Partage.
    $Steps += New-SimpleFriendStep 5 'Partager avec tes amis' "Envoie-leur cette ligne. Ils la collent dans la console Rust (touche F1), puis valident." 'OK' 'COPIER' 'copy'

    $Ui.SimpleFriendsSteps.ItemsSource = $null
    $Ui.SimpleFriendsSteps.ItemsSource = $Steps

    $Bloquantes = @($Steps | Where-Object EtatLabel -eq 'A FAIRE').Count
    $Ui.SimpleFriendsHeadline.Text = if ($Bloquantes -eq 0) {
        "Tout est prêt de ton côté - partage l'adresse"
    } else {
        "$Bloquantes étape(s) à régler avant que tes amis puissent entrer"
    }
    Refresh-FriendTestPanel
}

function Invoke-SimpleFriendsStep([string]$ActionId) {
    switch ($ActionId) {
        'configure' {
            Apply-InterfaceMode -Mode 'advanced'
            Select-AdvancedNav -Tab 1
            $Ui.MainTabs.SelectedIndex = 1
            Set-Activity 'Crée un serveur et coche « ouvert aux amis ».'
        }
        'start' {
            $Public = @(Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1
            if (-not $Public) { throw "Aucun serveur public configuré." }
            Start-RustInstance -Id ([string]$Public.id)
        }
        'firewall' {
            # On n'a pas les droits administrateur : on ouvre la console pare-feu
            # et on met la commande exacte dans le presse-papiers.
            $Port = 28115
            $Public = @(Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1
            if ($Public) { $Port = [int]$Public.serverPort }
            $Rule = "New-NetFirewallRule -DisplayName 'Rust - Serveur amis UDP $Port' -Direction Inbound -Protocol UDP -LocalPort $Port -Action Allow"
            [Windows.Clipboard]::SetText($Rule)
            Start-Process 'wf.msc'
            Show-Info "La console du pare-feu Windows s'ouvre.`n`nLa commande pour créer la règle a été copiée dans ton presse-papiers. Colle-la dans un PowerShell ouvert en administrateur si tu préfères aller vite :`n`n$Rule"
        }
        'router' {
            $Batch = Join-Path $ServerRoot 'OUVRIR-REGLAGE-LIVEBOX.bat'
            if (Test-Path -LiteralPath $Batch) { Start-Process $Batch }
            else {
                $Gateway = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4DefaultGateway.NextHop
                if ($Gateway) { Start-Process ("http://$Gateway") } else { throw "Passerelle réseau introuvable." }
            }
            Set-Activity "Cherche « redirection de port » ou « NAT/PAT » dans l'interface de ta box."
        }
        'test' {
            Show-Info "Trois façons de vérifier que l'extérieur te joint :`n`n1. Un ami lance Rust et colle ton adresse.`n2. Tu partages la connexion de ton téléphone sur un second PC et tu testes depuis là.`n3. Un service de test de port UDP en ligne.`n`nAttention : tester depuis ce PC ou depuis ton propre réseau ne prouve rien, ça passe par le réseau local."
        }
        'friend-test' { Start-FriendTest }
        'copy' {
            [Windows.Clipboard]::SetText($Ui.SimpleFriendsAddress.Text)
            Set-Activity 'Adresse copiée : envoie-la à tes amis.'
        }
    }
}

# ----- Vue simple : Mods & Modes -------------------------------------------
# La page Extensions avancee reste la reference technique. Cette vue n'expose
# que ce qu'un debutant doit comprendre : ce qui existe, dans quel etat, et le
# seul bouton qui change cet etat.

function Get-SimpleModDescription([string]$FileBase) {
    switch ($FileBase) {
        'RustRPG'          { 'Niveaux, quêtes, économie et vagues de zombies.' }
        'RustGameHub'      { 'Lobby central et modes en équipe : drapeau, domination, S&D.' }
        'RustDuel'         { 'Duels 1v1 à 4v4 avec classement et tournois.' }
        'RustGunGame'      { 'Chacun pour soi : 26 armes qui changent à chaque frag.' }
        'RustTowerDefense' { 'Défense coopérative : tours, vagues et mode infini.' }
        'RustTraining'     { 'Stand de tir avec cibles mobiles et sparring à l''arme blanche.' }
        'RustStats'        { 'Statistiques de parties et classements des joueurs.' }
        default            { 'Extension détectée sur ce serveur.' }
    }
}

function Get-SimplePluginCategoryStyle([string]$CategoryId) {
    switch ($CategoryId) {
        'mode'           { return [pscustomobject]@{ Fond='#342018'; Border='#8A402B'; Text='#EFA45D' } }
        'gameplay'       { return [pscustomobject]@{ Fond='#242D1D'; Border='#4C6135'; Text='#AAD36F' } }
        'economy'        { return [pscustomobject]@{ Fond='#302919'; Border='#76612C'; Text='#E7C46C' } }
        'administration' { return [pscustomobject]@{ Fond='#1C2830'; Border='#36566A'; Text='#8CC7E8' } }
        'utility'        { return [pscustomobject]@{ Fond='#27232E'; Border='#554568'; Text='#C0A2E7' } }
        default          { return [pscustomobject]@{ Fond='#232019'; Border='#484039'; Text='#A79D91' } }
    }
}

function Get-SimplePluginHealthStyle([string]$HealthId) {
    switch ($HealthId) {
        'error'   { return [pscustomobject]@{ Fond='#4B1E19'; Border='#893C32'; Text='#F08369' } }
        'warning' { return [pscustomobject]@{ Fond='#3A3122'; Border='#765B2C'; Text='#FFD479' } }
        default   { return [pscustomobject]@{ Fond='#1D3025'; Border='#315746'; Text='#9FD36F' } }
    }
}

function Update-SimplePluginCatalogView {
    $Plugins = @($script:PluginCatalog)
    $Search = ([string]$Ui.SimpleModsSearchBox.Text).Trim().ToLowerInvariant()
    $CategoryFilter = Get-SelectedText $Ui.SimpleModsCategoryCombo
    $StateFilter = Get-SelectedText $Ui.SimpleModsStateCombo

    $Filtered = @($Plugins | Where-Object {
        $Plugin = $_
        $MatchesSearch = (-not $Search) -or ([string]$Plugin.SearchText).Contains($Search)
        $MatchesCategory = switch ($CategoryFilter) {
            {$_ -in @('Modes de jeu','Game modes')} { [string]$Plugin.CategoryId -eq 'mode' }
            'Gameplay'        { [string]$Plugin.CategoryId -eq 'gameplay' }
            {$_ -in @('Économie','Economy')} { [string]$Plugin.CategoryId -eq 'economy' }
            'Administration'  { [string]$Plugin.CategoryId -eq 'administration' }
            {$_ -in @('Utilitaires','Utilities')} { [string]$Plugin.CategoryId -eq 'utility' }
            {$_ -in @('Autres','Other')} { [string]$Plugin.CategoryId -eq 'other' }
            default           { $true }
        }
        $MatchesState = switch ($StateFilter) {
            {$_ -in @('Actifs','Enabled')} { [string]$Plugin.Etat -eq 'Actif' }
            {$_ -in @('Désactivés','Disabled')} { [string]$Plugin.Etat -eq 'Desactive' }
            {$_ -in @('À vérifier','Needs review')} { [string]$Plugin.HealthId -ne 'ok' }
            default        { $true }
        }
        $MatchesSearch -and $MatchesCategory -and $MatchesState
    })

    $Environment = Get-DisplayedEnvironment
    $Rows = @(foreach ($Plugin in $Filtered) {
        $Active = [string]$Plugin.Etat -eq 'Actif'
        $CategoryStyle = Get-SimplePluginCategoryStyle ([string]$Plugin.CategoryId)
        $HealthStyle = Get-SimplePluginHealthStyle ([string]$Plugin.HealthId)
        $Description = if ([string]$Plugin.Description) { [string]$Plugin.Description } else { Get-SimpleModDescription ([string]$Plugin.FileBase) }
        [pscustomobject]@{
            Nom              = [string]$Plugin.Nom
            Description      = $Description
            MetadataLine     = [string]$Plugin.MetadataLine
            CapabilityLine   = if ([bool]$Plugin.IsMode) { 'DÉBLOQUE : ' + [string]$Plugin.CapabilityLabel } else { '' }
            IsMode           = [bool]$Plugin.IsMode
            FileBase         = [string]$Plugin.FileBase
            CategoryLabel    = [string]$Plugin.CategoryLabel
            CategoryFond     = [string]$CategoryStyle.Fond
            CategoryBorder   = [string]$CategoryStyle.Border
            CategoryCouleur  = [string]$CategoryStyle.Text
            EtatLabel        = if ($Active) { 'ACTIF' } else { 'DÉSACTIVÉ' }
            EtatCouleur      = if ($Active) { '#9FD36F' } else { '#8C8276' }
            EtatFond         = if ($Active) { '#24422E' } else { '#232019' }
            HealthLabel      = [string]$Plugin.HealthLabel
            HealthFond       = [string]$HealthStyle.Fond
            HealthBorder     = [string]$HealthStyle.Border
            HealthCouleur    = [string]$HealthStyle.Text
            IssueText        = if ([string]$Plugin.IssueText) { [string]$Plugin.IssueText } else { 'Métadonnées, code source et état cohérents.' }
            ActionLabel      = if ($Active) { 'DÉSACTIVER' } else { 'ACTIVER' }
            ActionPossible   = [bool]$Environment.Installed
        }
    })

    $Ui.SimpleModsList.ItemsSource = $null
    $Ui.SimpleModsList.ItemsSource = $Rows
    $Ui.SimpleModsDetectedCountText.Text = [string]$Plugins.Count
    $Ui.SimpleModsActiveCountText.Text = [string](@($Plugins | Where-Object Etat -eq 'Actif').Count)
    $ModeIds = @($Plugins | ForEach-Object { @($_.CapabilityIds) } | Sort-Object -Unique)
    $Ui.SimpleModsModeCountText.Text = [string]$ModeIds.Count
    $Ui.SimpleModsIssueCountText.Text = [string](@($Plugins | Where-Object HealthId -ne 'ok').Count)

    if ($Rows.Count -eq 0) {
        $Ui.SimpleModsEmptyText.Visibility = [Windows.Visibility]::Visible
        $Ui.SimpleModsEmptyText.Text = if (-not $Environment.Installed) {
            'Installe Carbon ou Oxide/uMod pour pouvoir importer et charger des plugins.'
        } elseif ($Plugins.Count -eq 0) {
            "$($Environment.Label) est installé mais aucun plugin .cs n'est présent."
        } else {
            'Aucun plugin ne correspond à cette recherche ou à ces filtres.'
        }
    }
    else { $Ui.SimpleModsEmptyText.Visibility = [Windows.Visibility]::Collapsed }

    $RunningSuffix = if ((Get-RustRpgServerState).Running) { '' } else { ' • serveur arrêté' }
    $Ui.SimpleModsListLabel.Text = "CATALOGUE  •  $($Rows.Count) résultat(s) sur $($Plugins.Count)  •  installation partagée$RunningSuffix"
}

function Refresh-SimpleMods {
    $Environment = Get-DisplayedEnvironment
    $script:PluginCatalog = @(Get-DisplayedPlugins)

    if (-not $Environment.Installed) {
        $Ui.SimpleModsEnvTitle.Text = 'SERVEUR VANILLA'
        $Ui.SimpleModsEnvText.Text = "Aucun moteur de mods n'est installé. Le diagnostic reste en lecture seule et ne crée aucun dossier de framework."
        $Ui.SimpleModsEnvActionButton.Content = 'INSTALLER CARBON'
        $Ui.SimpleModsEnvActionButton.Visibility = [Windows.Visibility]::Visible
        $Ui.SimpleModsImportButton.IsEnabled = $false
    }
    else {
        $Ui.SimpleModsEnvTitle.Text = "CATALOGUE $($Environment.Label) ACTIF"
        $Version = if ($Environment.Version) { " • version $($Environment.Version)" } else { '' }
        $Ui.SimpleModsEnvText.Text = "Analyse automatique de $($script:PluginCatalog.Count) fichier(s) .cs$Version. Les plugins sont partagés par les instances de cette installation."
        $Ui.SimpleModsEnvActionButton.Visibility = [Windows.Visibility]::Collapsed
        $Ui.SimpleModsImportButton.IsEnabled = $true
    }
    Update-SimplePluginCatalogView
}

function Invoke-TrackedPluginToggle([string]$FileBase,[bool]$Enabled) {
    if (-not $FileBase) { throw 'Nom de plugin manquant.' }
    $Verb = if ($Enabled) { 'Activation' } else { 'Désactivation' }
    $Metadata = [pscustomobject]@{ fileBase=$FileBase; enabled=$Enabled }
    return Invoke-TrackedSynchronousAction -Type PluginToggle -Title ("$Verb de $FileBase") -Stage 'MISE À JOUR DU PLUGIN' -Detail 'Le fichier du plugin est déplacé dans son état actif ou désactivé.' -RetryAction 'plugin-toggle' -Metadata $Metadata -Action {
        Set-RustPluginEnabled -ServerRoot $ServerRoot -FileBase $FileBase -Enabled $Enabled
    }
}

function Invoke-TrackedPluginImport([string]$SourcePath) {
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'Le fichier source du plugin est introuvable.' }
    $Name = [IO.Path]::GetFileNameWithoutExtension($SourcePath)
    return Invoke-TrackedSynchronousAction -Type PluginImport -Title ("Import du plugin " + $Name) -Stage 'COPIE & VALIDATION' -Detail 'Le plugin est copié dans le catalogue du framework actif.' -RetryAction 'plugin-import' -Metadata ([pscustomobject]@{ sourcePath=$SourcePath }) -Action {
        Import-RustPlugin -ServerRoot $ServerRoot -SourcePath $SourcePath
    }
}

function Invoke-SimpleModToggle([string]$FileBase) {
    if (-not $FileBase) { return }
    $Plugin = @(Get-DisplayedPlugins | Where-Object FileBase -eq $FileBase) | Select-Object -First 1
    if (-not $Plugin) { throw "Mod introuvable : $FileBase" }

    $Enable = $Plugin.Etat -ne 'Actif'
    $Verbe = if ($Enable) { 'Activer' } else { 'Désactiver' }

    # Activer ou desactiver un mod pendant une partie coupe les joueurs qui y
    # sont : on passe par le meme garde-fou que le rechargement de plugin.
    if (-not (Confirm-Disruption "$Verbe le mod $($Plugin.Nom)")) {
        Set-Activity 'Action annulée.'
        return
    }

    Invoke-BusyAction { Invoke-TrackedPluginToggle -FileBase $FileBase -Enabled $Enable | Out-Null }
    Refresh-SimpleMods
    Refresh-Plugins
    Set-Activity "$($Plugin.Nom) : $(if ($Enable) { 'activé' } else { 'désactivé' })."
}

function Refresh-Plugins {
    $SelectedFileBase = if ($Ui.PluginGrid.SelectedItem) { [string]$Ui.PluginGrid.SelectedItem.FileBase } else { '' }
    $Plugins = @(Get-DisplayedPlugins)
    $script:PluginCatalog = @($Plugins)
    $Environment = Get-DisplayedEnvironment
    $Ui.PluginGrid.ItemsSource = $null
    $Ui.PluginGrid.ItemsSource = $Plugins
    if ($Plugins.Count -gt 0) {
        $Selection = if ($SelectedFileBase) { @($Plugins | Where-Object FileBase -eq $SelectedFileBase | Select-Object -First 1)[0] } else { @() }
        $PreferredPlugin = @($Plugins | Where-Object SdkSettingsCount -gt 0 | Select-Object -First 1)[0]
        $Ui.PluginGrid.SelectedItem = if ($Selection.Count) { $Selection[0] } elseif ($PreferredPlugin) { $PreferredPlugin } else { $Plugins[0] }
    }
    $Active = @($Plugins | Where-Object Etat -eq 'Actif').Count
    $Disabled = @($Plugins | Where-Object Etat -eq 'Desactive').Count
    $Loaded = @($Plugins | Where-Object EtatAffiche -like 'Charg*').Count
    $Errors = @($Plugins | Where-Object EtatAffiche -eq 'Erreur de compilation').Count
    $ModeCount = @($Plugins | ForEach-Object { @($_.CapabilityIds) } | Sort-Object -Unique).Count
    $IssueCount = @($Plugins | Where-Object HealthId -ne 'ok').Count
    $Runtime = if ((Get-RustRpgServerState).Running) { (" - $Loaded charg{0}(s) - $Errors erreur(s)" -f [char]0x00E9) } else { (" - serveur arr{0}t{1}" -f [char]0x00EA,[char]0x00E9) }
    $Ui.PluginSummaryText.Text = if (-not $Environment.Installed) {
        'Environnement vanilla — aucun framework de mod détecté.'
    } elseif ($Plugins.Count -eq 0) {
        "$($Environment.Label) est installé — aucun plugin .cs détecté."
    } else {
        ("$Active plugin(s) activ{0}(s) - $Disabled d{0}sactiv{0}(s) - $ModeCount mode(s) reconnu(s) - $IssueCount à vérifier$Runtime" -f [char]0x00E9)
    }
    $HasPlugins = $Plugins.Count -gt 0
    $Ui.PluginGridBorder.Visibility = if ($HasPlugins) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.PluginEmptyStateBorder.Visibility = if ($HasPlugins) { [Windows.Visibility]::Collapsed } else { [Windows.Visibility]::Visible }
    $Ui.InstallCarbonButton.Visibility = if (-not $Environment.Installed) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.InstallOxideButton.Visibility = if (-not $Environment.Installed) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.ResetPluginDataCheck.Visibility = if ($Plugins.Count -gt 0) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.DashPluginCountText.Text = [string]$Active
    Refresh-PluginCapabilities -Plugins @($Plugins)
    Refresh-DashboardMetrics
    Update-PluginSdkInspector
}

function Get-SelectedPlugin {
    $Plugin = $Ui.PluginGrid.SelectedItem
    if (-not $Plugin) { throw 'Selectionne un plugin dans la liste.' }
    return $Plugin
}

function Set-SelectedPluginState([bool]$Enabled) {
    $Plugin = Get-SelectedPlugin
    Invoke-TrackedPluginToggle -FileBase ([string]$Plugin.FileBase) -Enabled $Enabled | Out-Null
    Refresh-Plugins
    $PluginMessage = if($Enabled){"Plugin $($Plugin.Nom) active."}else{"Plugin $($Plugin.Nom) desactive."}
    Set-Activity $PluginMessage
}

function Reload-SelectedPlugin {
    $Plugin = Get-SelectedPlugin
    if ($Plugin.Etat -ne 'Actif') { throw 'Active le plugin avant de le recharger.' }
    if (-not (Get-RustRpgServerState).Running) { Show-Info 'Le plugin sera charge au prochain demarrage du serveur.'; return }
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
    $Command = $Context.ConsolePrefix + ".reload " + $Plugin.FileBase
    Invoke-AfterDisruptionCheck -ActionLabel "Recharger $($Plugin.Nom)" -Continuation {
        Queue-ServerOperation -Operation command -Command $Command -Label "rechargement de $($Plugin.Nom)" -OnSuccess {
            param($Response)
            Refresh-Plugins
            Set-Activity ("Rechargement : " + $Response)
        }
    }
}

function Import-PluginFile {
    $Environment = Get-DisplayedEnvironment
    if (-not $Environment.Installed) { throw "Installe Carbon ou Oxide avant d'importer un plugin .cs." }
    $Dialog = New-Object Windows.Forms.OpenFileDialog
    $Dialog.Filter = 'Plugin Carbon/Oxide (*.cs)|*.cs'
    $Dialog.Title = 'Importer un plugin Rust'
    if ($Dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return }
    $Target = Invoke-TrackedPluginImport -SourcePath $Dialog.FileName
    Refresh-Plugins
    Set-Activity "Plugin importe : $Target"
}

function Archive-SelectedPlugin {
    $Plugin = Get-SelectedPlugin
    if (-not (Confirm-Action "Archiver le plugin $($Plugin.Nom) ?`nIl sera decharge puis deplace dans backups/plugins." 'Archiver un plugin')) { return }
    $Path = Invoke-TrackedSynchronousAction -Type PluginArchive -Title ("Archivage du plugin " + [string]$Plugin.FileBase) -Stage 'ARCHIVAGE' -Detail 'Le plugin est désactivé puis déplacé vers les sauvegardes.' -Action {
        Archive-RustPlugin -ServerRoot $ServerRoot -FileBase $Plugin.FileBase
    }
    Refresh-Plugins
    Set-Activity "Plugin archive dans $Path"
}

function Refresh-ConfigFiles([string]$SelectPath = '') {
    $Paths = @()
    $Paths += Join-Path $ServerRoot 'config\server.cfg'
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
    if ($Context.Framework -eq 'carbon') {
        $Paths += Join-Path $Context.PluginRoot 'config.json'
        $Paths += Join-Path $Context.PluginRoot 'modules\AutoWipe\config.json'
    }
    $Paths += @(Get-ChildItem -LiteralPath $Context.ConfigRoot -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    $Items = @($Paths | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique | ForEach-Object {
        [pscustomobject]@{ Display = $_.Substring($ServerRoot.Length + 1); Path = $_ }
    })
    $Ui.ConfigFileCombo.ItemsSource = $null
    $Ui.ConfigFileCombo.DisplayMemberPath = 'Display'
    $Ui.ConfigFileCombo.ItemsSource = $Items
    if ($SelectPath) {
        $Ui.ConfigFileCombo.SelectedItem = $Items | Where-Object Path -eq $SelectPath | Select-Object -First 1
    }
    elseif ($Items.Count -gt 0) { $Ui.ConfigFileCombo.SelectedIndex = 0 }
}

function Get-VisualValueType($Value) {
    if ($null -eq $Value) { return 'Null' }
    if ($Value -is [bool]) { return 'Booleen' }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) { return 'Entier' }
    if ($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) { return 'Nombre' }
    if ($Value -is [array] -or $Value -is [Collections.IList]) { return 'JSON' }
    if ($Value -is [Management.Automation.PSCustomObject]) { return 'Objet JSON' }
    return 'Texte'
}

function ConvertTo-VisualValueText($Value,[string]$Type) {
    if ($Type -eq 'Null') { return 'null' }
    if ($Type -eq 'Booleen') { return ([string]$Value).ToLowerInvariant() }
    if ($Type -in @('Entier','Nombre')) { return [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture) }
    if ($Type -in @('JSON','Objet JSON')) { return ConvertTo-Json -InputObject $Value -Depth 50 -Compress }
    return [string]$Value
}

function Add-JsonVisualRows($Value,[object[]]$Segments,[string]$DisplayPath,[Collections.Generic.List[object]]$Rows) {
    if ($Value -is [Management.Automation.PSCustomObject]) {
        $Properties = @($Value.PSObject.Properties)
        if ($Properties.Count -gt 0) {
            foreach ($Property in $Properties) {
                $ChildSegments = @($Segments) + @([string]$Property.Name)
                $ChildPath = if ($DisplayPath) { "$DisplayPath > $($Property.Name)" } else { [string]$Property.Name }
                Add-JsonVisualRows -Value $Property.Value -Segments $ChildSegments -DisplayPath $ChildPath -Rows $Rows
            }
            return
        }
    }

    $Type = Get-VisualValueType $Value
    $Rows.Add([pscustomobject]@{
        Path       = if ($DisplayPath) { $DisplayPath } else { '$' }
        Type       = $Type
        Value      = ConvertTo-VisualValueText $Value $Type
        Segments   = @($Segments)
        LineIndex  = -1
        Key        = ''
        Indent     = ''
        Quoted     = $false
    })
}

function Load-VisualConfigFromRaw {
    $Item = $Ui.ConfigFileCombo.SelectedItem
    if (-not $Item) { return }
    $Rows = New-Object 'Collections.Generic.List[object]'
    $Text = [string]$Ui.ConfigEditor.Text

    if ([IO.Path]::GetExtension($Item.Path) -eq '.json') {
        $script:VisualConfigKind = 'json'
        $script:VisualConfigObject = $Text | ConvertFrom-Json
        if ($script:VisualConfigObject -isnot [Management.Automation.PSCustomObject]) {
            throw 'La racine du JSON doit etre un objet pour utiliser l editeur visuel.'
        }
        Add-JsonVisualRows -Value $script:VisualConfigObject -Segments @() -DisplayPath '' -Rows $Rows
        $Ui.FormatConfigButton.IsEnabled = $true
        $Ui.VisualConfigSummaryText.Text = "$($Rows.Count) valeur(s) JSON editable(s). Les tableaux restent editables au format JSON compact."
    }
    else {
        $script:VisualConfigKind = 'cfg'
        $script:VisualConfigLineEnding = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
        $script:VisualConfigLines = @([regex]::Split($Text,'\r?\n'))
        for ($Index = 0; $Index -lt $script:VisualConfigLines.Count; $Index++) {
            $Line = [string]$script:VisualConfigLines[$Index]
            if ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith('#') -or $Line.TrimStart().StartsWith('//')) { continue }
            $Match = [regex]::Match($Line,'^(\s*)([^\s]+)\s+(.+?)\s*$')
            if (-not $Match.Success) { continue }
            $Key = $Match.Groups[2].Value
            $Token = $Match.Groups[3].Value
            $Quoted = $Token.Length -ge 2 -and $Token.StartsWith('"') -and $Token.EndsWith('"')
            if ($Quoted) {
                $Value = $Token.Substring(1,$Token.Length - 2).Replace('\"','"')
                $Type = 'Texte'
            }
            elseif ($Token -match '^(?i:true|false)$') { $Value = $Token.ToLowerInvariant(); $Type = 'Booleen' }
            elseif ($Token -match '^[+-]?\d+$') { $Value = $Token; $Type = 'Entier' }
            elseif ($Token -match '^[+-]?(\d+([.,]\d*)?|[.,]\d+)$') { $Value = $Token.Replace(',','.'); $Type = 'Nombre' }
            else { $Value = $Token; $Type = 'Texte' }
            $Rows.Add([pscustomobject]@{
                Path       = $Key
                Type       = $Type
                Value      = [string]$Value
                Segments   = @()
                LineIndex  = $Index
                Key        = $Key
                Indent     = $Match.Groups[1].Value
                Quoted     = $Quoted
            })
        }
        $Ui.FormatConfigButton.IsEnabled = $false
        $Ui.VisualConfigSummaryText.Text = "$($Rows.Count) parametre(s) server.cfg editable(s). Commentaires et ordre des lignes sont conserves."
    }

    $script:VisualConfigRows = $Rows.ToArray()
    $Ui.VisualConfigGrid.ItemsSource = $null
    $Ui.VisualConfigGrid.ItemsSource = $script:VisualConfigRows
}

function ConvertFrom-VisualValue([string]$Text,[string]$Type,[string]$Path) {
    switch ($Type) {
        'Booleen' {
            switch ($Text.Trim().ToLowerInvariant()) {
                { $_ -in @('true','1','oui','yes') } { return $true }
                { $_ -in @('false','0','non','no') } { return $false }
                default { throw "$Path : booleen invalide. Utilise true ou false." }
            }
        }
        'Entier' {
            $Number = [long]0
            if (-not [long]::TryParse($Text.Trim(),[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$Number)) {
                throw "$Path : nombre entier invalide."
            }
            return $Number
        }
        'Nombre' {
            $Number = [double]0
            $Normalized = $Text.Trim().Replace(',','.')
            if (-not [double]::TryParse($Normalized,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$Number)) {
                throw "$Path : nombre invalide."
            }
            return $Number
        }
        'Null' {
            if ($Text.Trim() -ne 'null') { throw "$Path : laisse la valeur null ou change-la dans la source avancee." }
            return $null
        }
        { $_ -in @('JSON','Objet JSON') } {
            try {
                $Parsed = $Text | ConvertFrom-Json
                if ($Type -eq 'JSON' -and $Parsed -is [array]) { return ,$Parsed }
                return $Parsed
            }
            catch { throw "$Path : JSON invalide - $($_.Exception.Message)" }
        }
        default { return [string]$Text }
    }
}

function Set-JsonValueAtPath($Root,[object[]]$Segments,$Value) {
    if ($Segments.Count -eq 0) { throw 'La racine JSON ne peut pas etre remplacee depuis la grille.' }
    $Current = $Root
    for ($Index = 0; $Index -lt $Segments.Count - 1; $Index++) {
        $Property = $Current.PSObject.Properties[[string]$Segments[$Index]]
        if (-not $Property) { throw "Chemin JSON introuvable : $($Segments -join ' > ')" }
        $Current = $Property.Value
    }
    $LastProperty = $Current.PSObject.Properties[[string]$Segments[-1]]
    if (-not $LastProperty) { throw "Parametre JSON introuvable : $($Segments -join ' > ')" }
    $LastProperty.Value = $Value
}

function Sync-VisualConfigToRaw {
    $null = $Ui.VisualConfigGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Cell,$true)
    $null = $Ui.VisualConfigGrid.CommitEdit([Windows.Controls.DataGridEditingUnit]::Row,$true)
    if ($script:VisualConfigKind -eq 'json') {
        foreach ($Row in @($script:VisualConfigRows)) {
            $Value = ConvertFrom-VisualValue ([string]$Row.Value) ([string]$Row.Type) ([string]$Row.Path)
            Set-JsonValueAtPath -Root $script:VisualConfigObject -Segments @($Row.Segments) -Value $Value
        }
        $Ui.ConfigEditor.Text = ConvertTo-Json -InputObject $script:VisualConfigObject -Depth 50
    }
    elseif ($script:VisualConfigKind -eq 'cfg') {
        $Lines = @($script:VisualConfigLines)
        foreach ($Row in @($script:VisualConfigRows)) {
            $Value = ConvertFrom-VisualValue ([string]$Row.Value) ([string]$Row.Type) ([string]$Row.Path)
            if ($Row.Type -eq 'Booleen') { $Token = ([string]$Value).ToLowerInvariant() }
            elseif ($Row.Type -in @('Entier','Nombre')) { $Token = [Convert]::ToString($Value,[Globalization.CultureInfo]::InvariantCulture) }
            else {
                $Escaped = ([string]$Value).Replace('"','\"')
                $Token = if ($Row.Quoted -or $Row.Type -eq 'Texte') { '"' + $Escaped + '"' } else { $Escaped }
            }
            $Lines[[int]$Row.LineIndex] = ([string]$Row.Indent) + ([string]$Row.Key) + ' ' + $Token
        }
        $Ui.ConfigEditor.Text = $Lines -join $script:VisualConfigLineEnding
    }
}

function Validate-SelectedConfig {
    $Item = $Ui.ConfigFileCombo.SelectedItem
    if (-not $Item) { throw 'Choisis un fichier de configuration.' }
    if ($Ui.ConfigModeTabs.SelectedIndex -eq 0) { Sync-VisualConfigToRaw }
    if ([IO.Path]::GetExtension($Item.Path) -eq '.json') {
        $null = $Ui.ConfigEditor.Text | ConvertFrom-Json
        $Ui.VisualConfigSummaryText.Text = "$($script:VisualConfigRows.Count) valeur(s) verifiee(s) - JSON valide."
    }
    else {
        $Lines = @([regex]::Split([string]$Ui.ConfigEditor.Text,'\r?\n'))
        for ($Index = 0; $Index -lt $Lines.Count; $Index++) {
            $Line = [string]$Lines[$Index]
            if ([string]::IsNullOrWhiteSpace($Line) -or $Line.TrimStart().StartsWith('#') -or $Line.TrimStart().StartsWith('//')) { continue }
            if ($Line -notmatch '^\s*[^\s]+\s+.+$') { throw "server.cfg invalide a la ligne $($Index + 1) : $Line" }
        }
        $Ui.VisualConfigSummaryText.Text = "$($script:VisualConfigRows.Count) parametre(s) verifie(s) - server.cfg valide."
    }
    Set-Activity "Configuration valide : $($Item.Display)"
    return $true
}

function Load-SelectedConfig {
    $Item = $Ui.ConfigFileCombo.SelectedItem
    if (-not $Item) { return }
    $Ui.ConfigEditor.Text = Get-Content -LiteralPath $Item.Path -Raw -Encoding UTF8
    Load-VisualConfigFromRaw
    Set-Activity "Configuration chargee : $($Item.Display)"
}

function Format-SelectedConfig {
    $Item = $Ui.ConfigFileCombo.SelectedItem
    if (-not $Item -or [IO.Path]::GetExtension($Item.Path) -ne '.json') { throw 'Le formatage est reserve aux fichiers JSON.' }
    if ($Ui.ConfigModeTabs.SelectedIndex -eq 0) { Sync-VisualConfigToRaw }
    $Object = $Ui.ConfigEditor.Text | ConvertFrom-Json
    $Ui.ConfigEditor.Text = ConvertTo-Json -InputObject $Object -Depth 50
    Load-VisualConfigFromRaw
    Set-Activity 'JSON valide et formate.'
}

function Save-SelectedConfig {
    $Item = $Ui.ConfigFileCombo.SelectedItem
    if (-not $Item) { throw 'Choisis un fichier de configuration.' }
    $null = Validate-SelectedConfig

    # Le rechargement automatique qui suit peut couper une partie : on demande
    # avant d'ecrire, pour ne pas laisser un fichier enregistre non applique.
    $ReloadPlugin = $null
    $PluginContext = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
    $ConfigPrefix = [IO.Path]::GetFullPath($PluginContext.ConfigRoot).TrimEnd('\') + '\'
    if ((Get-RustRpgServerState).Running -and [IO.Path]::GetFullPath([string]$Item.Path).StartsWith($ConfigPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetExtension([string]$Item.Path) -eq '.json') {
        $PluginName = [IO.Path]::GetFileNameWithoutExtension($Item.Path)
        if (Confirm-Disruption "Appliquer la configuration de $PluginName (rechargement)") {
            $ReloadPlugin = $PluginName
        }
    }

    $Backup = $Item.Path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $Item.Path -Destination $Backup -Force
    Write-Utf8File -Path $Item.Path -Content $Ui.ConfigEditor.Text
    Load-VisualConfigFromRaw

    if ($ReloadPlugin) {
        $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
        Queue-ServerOperation -Operation command -Command ($Context.ConsolePrefix + ".reload " + $ReloadPlugin) -Label "application de $ReloadPlugin" -OnSuccess {
            param($Response)
            Refresh-Plugins
            Set-Activity "Fichier enregistre et $ReloadPlugin recharge. Copie : $Backup"
        }
        return
    }
    Set-Activity "Fichier enregistre (rechargement non applique). Copie : $Backup"
}

function Select-NetworkComboCode($Combo,[string]$Code) {
    $Match = @($Combo.ItemsSource | Where-Object Code -eq $Code) | Select-Object -First 1
    if ($Match) { $Combo.SelectedItem = $Match } elseif ($Combo.Items.Count) { $Combo.SelectedIndex = 0 }
}

function Refresh-TailscaleDisplay {
    $Tail = Get-RustTailscaleStatus
    $StateLabel = ''
    $StateColor = '#E7A84D'
    if (-not $Tail.Installed) {
        $StateLabel = Get-LocalizedUiText 'NON INSTALLÉ' 'NOT INSTALLED'
        $StateColor = '#E76A4C'
    }
    elseif ($Tail.Running) {
        $StateLabel = Get-LocalizedUiText 'CONNECTÉ' 'CONNECTED'
        $StateColor = '#72D79B'
    }
    elseif ($Tail.NeedsLogin) {
        $StateLabel = Get-LocalizedUiText 'CONNEXION REQUISE' 'LOGIN REQUIRED'
    }
    else {
        $StateLabel = Get-LocalizedUiText 'HORS LIGNE' 'OFFLINE'
    }
    $Ui.NetworkTailscaleStateText.Text = $StateLabel
    $Ui.NetworkTailscaleStateText.Foreground = $BrushConverter.ConvertFromString($StateColor)
    $Ui.NetworkTailscaleIpText.Text = if ($Tail.IPv4) { [string]$Tail.IPv4 } else { '—' }
    $DeviceParts = @([string]$Tail.HostName,[string]$Tail.TailnetName) | Where-Object { $_ }
    $Ui.NetworkTailscaleDeviceText.Text = if ($DeviceParts.Count) { $DeviceParts -join ' · ' } elseif ($Tail.Installed) { [string]$Tail.ServiceStatus } else { '—' }
    $Ui.NetworkTailscalePeersText.Text = if ($Tail.Running) { "$($Tail.OnlinePeerCount) / $($Tail.PeerCount)" } else { '0' }
    $Ui.NetworkTailscaleInstallButton.IsEnabled = -not [bool]$Tail.Installed
    $Ui.NetworkTailscaleInstallButton.Content = if ($Tail.Installed) { Get-LocalizedUiText 'INSTALLÉ' 'INSTALLED' } else { Get-LocalizedUiText 'INSTALLER TAILSCALE' 'INSTALL TAILSCALE' }
    $Ui.NetworkTailscaleLoginButton.IsEnabled = [bool]$Tail.Installed -and -not [bool]$Tail.Running
    $Ui.NetworkTailscaleEnableButton.IsEnabled = [bool]$Tail.Running
    $Ui.NetworkTailscaleInviteButton.IsEnabled = [bool]$Tail.Running
    $Ui.NetworkTailscaleCopyGuideButton.IsEnabled = [bool]$Tail.Running
    $Ui.NetworkTailscaleHelpText.Text = if (-not $Tail.Installed) {
        Get-LocalizedUiText "Installation officielle vérifiée par signature numérique. Windows demandera l'autorisation administrateur." 'Official installer verified by digital signature. Windows will request administrator approval.'
    }
    elseif ($Tail.Running) {
        $Identity = if ($Tail.UserName) { " · $($Tail.UserName)" } else { '' }
        Get-LocalizedUiText "Prêt pour Rust$Identity. Aucun mot de passe ni jeton Tailscale n'est conservé par le Control Center." "Ready for Rust$Identity. The Control Center stores no Tailscale password or token."
    }
    elseif ($Tail.LastError) {
        (Get-LocalizedUiText 'Tailscale est installé mais son état est indisponible : ' 'Tailscale is installed but its status is unavailable: ') + [string]$Tail.LastError
    }
    else {
        Get-LocalizedUiText 'Connecte ce PC à Tailscale, puis invite ton ami dans le même réseau privé.' 'Connect this PC to Tailscale, then invite your friend to the same private network.'
    }
    return $Tail
}

function Install-TailscaleFromControlCenter {
    Set-Activity (Get-LocalizedUiText 'Téléchargement et vérification de Tailscale...' 'Downloading and verifying Tailscale...')
    $Result = Invoke-BusyAction { Install-RustTailscale }
    if ($Result.AlreadyInstalled) {
        Refresh-TailscaleDisplay | Out-Null
        Set-Activity (Get-LocalizedUiText 'Tailscale est déjà installé.' 'Tailscale is already installed.')
        return
    }
    Show-Info (Get-LocalizedUiText "L'installateur officiel Tailscale a été vérifié et lancé. Accepte la demande Windows, termine l'installation, puis clique sur SE CONNECTER." 'The official Tailscale installer was verified and launched. Approve the Windows prompt, finish installation, then select LOG IN.') 'Tailscale'
    Set-Activity (Get-LocalizedUiText "Installateur Tailscale lancé." 'Tailscale installer started.')
}

function Connect-TailscaleFromControlCenter {
    $Tail = Get-RustTailscaleStatus
    if (-not $Tail.Installed) { throw "Installe d'abord Tailscale." }
    if ($Tail.Running) { Set-Activity 'Tailscale est déjà connecté.'; return }
    if ($Tail.NeedsLogin -or $Tail.BackendState -in @('NeedsLogin','NoState','Unavailable')) { $null = Start-RustTailscaleLogin }
    else { $null = Start-RustTailscaleUp }
    Set-Activity (Get-LocalizedUiText "Authentification Tailscale ouverte dans le navigateur. L'état sera actualisé automatiquement." 'Tailscale authentication opened in the browser. Status will refresh automatically.')
}

function Enable-TailscaleForRust {
    $Tail = Get-RustTailscaleStatus
    if (-not $Tail.Running -or -not $Tail.IPv4) { throw "Tailscale doit être connecté avant de l'utiliser pour Rust." }
    Select-NetworkComboCode $Ui.NetworkAccessModeCombo 'Tailscale'
    Save-NetworkAccessSettings
    $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
    if (-not $Instance.Count) { throw 'Aucun serveur amis public configuré.' }
    $HostName = if ($Tail.DnsName) { [string]$Tail.DnsName } else { [string]$Tail.IPv4 }
    $Command = "client.connect ${HostName}:$([int]$Instance[0].serverPort)"
    [Windows.Clipboard]::SetText($Command)
    Show-Info ((Get-LocalizedUiText 'Mode Tailscale activé. Commande copiée :' 'Tailscale mode enabled. Command copied:') + "`n`n$Command") 'Tailscale'
}

function Copy-TailscaleFriendGuide {
    $Tail = Get-RustTailscaleStatus
    if (-not $Tail.Running -or -not $Tail.IPv4) { throw "Tailscale n'est pas connecté." }
    $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
    if (-not $Instance.Count) { throw 'Aucun serveur amis public configuré.' }
    $HostName = if ($Tail.DnsName) { [string]$Tail.DnsName } else { [string]$Tail.IPv4 }
    $Command = "client.connect ${HostName}:$([int]$Instance[0].serverPort)"
    $Guide = @(
        (Get-LocalizedUiText 'Pour rejoindre mon serveur Rust :' 'To join my Rust server:'),
        '1. Installe Tailscale : https://tailscale.com/download/windows',
        (Get-LocalizedUiText "2. Accepte mon invitation Tailscale et vérifie que l'application indique Connecté." '2. Accept my Tailscale invitation and make sure the app says Connected.'),
        (Get-LocalizedUiText '3. Lance Rust, ouvre la console avec F1 et colle :' '3. Start Rust, open the console with F1 and paste:'),
        $Command
    ) -join [Environment]::NewLine
    [Windows.Clipboard]::SetText($Guide)
    Set-Activity (Get-LocalizedUiText "Guide Tailscale pour l'ami copié." 'Tailscale friend guide copied.')
}

function Refresh-NetworkAccessSettings {
    $Config = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    if (-not $Ui.NetworkDdnsProviderCombo.ItemsSource) {
        $Ui.NetworkDdnsProviderCombo.DisplayMemberPath = 'Label'
        $Ui.NetworkDdnsProviderCombo.ItemsSource = @(
            [pscustomobject]@{Code='Disabled';Label=Get-LocalizedUiText 'Désactivé' 'Disabled'},
            [pscustomobject]@{Code='DuckDNS';Label='DuckDNS'},
            [pscustomobject]@{Code='NoIP';Label='No-IP'}
        )
        $Ui.NetworkAccessModeCombo.DisplayMemberPath = 'Label'
        $Ui.NetworkAccessModeCombo.ItemsSource = @(
            [pscustomobject]@{Code='Direct';Label=Get-LocalizedUiText 'Direct / routeur' 'Direct / router'},
            [pscustomobject]@{Code='Tailscale';Label='Tailscale'},
            [pscustomobject]@{Code='CustomUdp';Label=Get-LocalizedUiText 'Tunnel UDP public' 'Public UDP tunnel'}
        )
    }
    $Ui.NetworkDdnsEnabledCheck.IsChecked = [bool]$Config.ddns.enabled
    Select-NetworkComboCode $Ui.NetworkDdnsProviderCombo ([string]$Config.ddns.provider)
    $Ui.NetworkDdnsHostnameBox.Text = [string]$Config.ddns.hostname
    $Ui.NetworkDdnsIntervalBox.Text = [string]$Config.ddns.intervalMinutes
    $Ui.NetworkDdnsUsernameBox.Text = [string]$Config.ddns.username
    $Ui.NetworkDdnsSecretBox.Password = ''
    Select-NetworkComboCode $Ui.NetworkAccessModeCombo ([string]$Config.access.mode)
    $Ui.NetworkTunnelHostBox.Text = [string]$Config.access.tunnelHost
    $Ui.NetworkTunnelPortBox.Text = if ([int]$Config.access.tunnelPort -gt 0) { [string]$Config.access.tunnelPort } else { '' }
    $SecretStored = [bool](Get-RustDdnsCredential -ServerRoot $ServerRoot)
    $Ui.NetworkDdnsStatusText.Text = if ([string]$Config.ddns.lastStatus -eq 'Success') { "Dernière mise à jour réussie : $($Config.ddns.lastDetail)" } elseif ([string]$Config.ddns.lastDetail) { [string]$Config.ddns.lastDetail } elseif ($SecretStored) { 'Clé DDNS enregistrée et chiffrée pour ce compte Windows.' } else { 'Aucune clé DDNS enregistrée.' }
    $StatePath = Get-RustNetworkAddressStatePath -ServerRoot $ServerRoot
    $State = if (Test-Path -LiteralPath $StatePath -PathType Leaf) { try { Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $null } } else { $null }
    if ($CapturePath) { $Ui.NetworkAddressTrackingText.Text='Réservation DHCP probable — LAN 192.0.2.10, publique 203.0.113.10.' }
    elseif ($State) {
        $Reservation = switch ([string]$State.reservationStatus) { 'Static' {'IP locale statique'} 'ProbableReservation' {'Réservation DHCP probable'} 'Changed' {'IP locale modifiée'} default {'Réservation DHCP non confirmée'} }
        $Change = if ([bool]$State.lanChanged) { " ALERTE : l’IP locale est passée de $($State.previousLanIp) à $($State.lastLanIp)." } elseif ([bool]$State.publicChanged) { " L’IP publique a changé : $($State.previousPublicIp) → $($State.lastPublicIp)." } else { '' }
        $Ui.NetworkAddressTrackingText.Text = "$Reservation — LAN $($State.lastLanIp), publique $($State.lastPublicIp).$Change"
    } else { $Ui.NetworkAddressTrackingText.Text = "Lance un diagnostic ou actualise l’adresse pour commencer le suivi." }
    $Tail = Refresh-TailscaleDisplay
    $Ui.NetworkAlternativeStatusText.Text = switch ([string]$Config.access.mode) {
        'Tailscale' { if ($Tail.Running) { "Tailscale prêt : $($Tail.IPv4). Chaque ami doit installer Tailscale et accepter l'invitation." } else { "Tailscale n'est pas connecté. Installe-le sur les deux PC ; un relais DERP peut augmenter le ping." } }
        'CustomUdp' { "Tunnel UDP : $($Config.access.tunnelHost):$($Config.access.tunnelPort). Relaye le port jeu UDP ; prévois aussi le query pour Steam." }
        default { 'Accès direct : ping optimal, mais les ports UDP du routeur doivent être redirigés.' }
    }
}

function Save-NetworkAccessSettings {
    $Provider = Get-SelectedText $Ui.NetworkDdnsProviderCombo
    if ($Ui.NetworkDdnsProviderCombo.SelectedItem -and $Ui.NetworkDdnsProviderCombo.SelectedItem.PSObject.Properties.Name -contains 'Code') { $Provider = [string]$Ui.NetworkDdnsProviderCombo.SelectedItem.Code }
    $Mode = if ($Ui.NetworkAccessModeCombo.SelectedItem) { [string]$Ui.NetworkAccessModeCombo.SelectedItem.Code } else { 'Direct' }
    $Interval = 0;if (-not [int]::TryParse($Ui.NetworkDdnsIntervalBox.Text.Trim(),[ref]$Interval)) { throw 'Intervalle DDNS invalide.' }
    $TunnelPort = 0;if ($Ui.NetworkTunnelPortBox.Text.Trim() -and -not [int]::TryParse($Ui.NetworkTunnelPortBox.Text.Trim(),[ref]$TunnelPort)) { throw 'Port du tunnel invalide.' }
    if ($Ui.NetworkDdnsSecretBox.Password) { $null = Set-RustDdnsCredential -ServerRoot $ServerRoot -Secret $Ui.NetworkDdnsSecretBox.Password }
    if ([bool]$Ui.NetworkDdnsEnabledCheck.IsChecked -and -not (Get-RustDdnsCredential -ServerRoot $ServerRoot)) { throw "Saisis d’abord le jeton ou la clé DDNS." }
    $null = Set-RustNetworkAccessConfig -ServerRoot $ServerRoot -DdnsEnabled ([bool]$Ui.NetworkDdnsEnabledCheck.IsChecked) -DdnsProvider $Provider -DdnsHostname $Ui.NetworkDdnsHostnameBox.Text -DdnsUsername $Ui.NetworkDdnsUsernameBox.Text -DdnsIntervalMinutes $Interval -AccessMode $Mode -TunnelHost $Ui.NetworkTunnelHostBox.Text -TunnelPort $TunnelPort
    try {
        $State = Update-RustNetworkAddressState -ServerRoot $ServerRoot
        $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
        if ($Instance.Count) { $Document = Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $Instance[0] -AddressState $State;$script:FriendCommandCache=[string]$Document.Endpoint.Command }
    } catch {}
    Refresh-NetworkAccessSettings
    Update-NetworkHeader
    Set-Activity "Profil d’accès amis enregistré."
}

function Test-NetworkDdnsNow {
    Save-NetworkAccessSettings
    $Result = Invoke-BusyAction { Invoke-RustDdnsUpdate -ServerRoot $ServerRoot }
    $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
    if ($Instance.Count) { $State=Update-RustNetworkAddressState -ServerRoot $ServerRoot -PublicIp ([string]$Result.Address);$Document=Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $Instance[0] -AddressState $State;$script:FriendCommandCache=[string]$Document.Endpoint.Command }
    Refresh-NetworkAccessSettings;Update-NetworkHeader
    Show-Info ("DNS dynamique actualisé : $($Result.Hostname) → $($Result.Address)") 'DDNS'
}

function Copy-NetworkAlternativeCommand {
    $State = Invoke-BusyAction { Update-RustNetworkAddressState -ServerRoot $ServerRoot }
    $Instance = @((Get-RustInstanceCatalog -ServerRoot $ServerRoot).instances | Where-Object isPublic | Select-Object -First 1)
    if (-not $Instance.Count) { throw 'Aucun serveur public configuré.' }
    $Document = Update-RustFriendConnectionDocument -ServerRoot $ServerRoot -Instance $Instance[0] -AddressState $State
    if ([string]$Document.Endpoint.Mode -eq 'Tailscale' -and -not [string]$Document.Endpoint.Host) { throw "Connecte d'abord Tailscale avant de copier la commande." }
    if ([string]$Document.Endpoint.Mode -eq 'CustomUdp' -and -not [string]$Document.Endpoint.Host) { throw "Renseigne d'abord l'adresse publique du tunnel UDP." }
    [Windows.Clipboard]::SetText([string]$Document.Endpoint.Command)
    $script:FriendCommandCache = [string]$Document.Endpoint.Command
    Update-NetworkHeader
    Set-Activity 'Commande unique copiée.'
}

function Start-DueDdnsWorker {
    if ($CapturePath -or $script:DdnsWorkerProcess) { return }
    $Config = Get-RustNetworkAccessConfig -ServerRoot $ServerRoot
    if (-not [bool]$Config.ddns.enabled) { return }
    $Last = [datetime]::MinValue
    if ([string]$Config.ddns.lastUpdateUtc) { try { $Last=[datetime]::Parse([string]$Config.ddns.lastUpdateUtc).ToLocalTime() } catch {} }
    if (((Get-Date)-$Last).TotalMinutes -lt [int]$Config.ddns.intervalMinutes -or ((Get-Date)-$script:DdnsWorkerLastLaunch).TotalSeconds -lt 30) { return }
    $WorkerPath=Join-Path $PSScriptRoot 'RustRPG-DdnsWorker.ps1';if(-not(Test-Path -LiteralPath $WorkerPath -PathType Leaf)){return}
    $PowerShellExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$LogRoot=Join-Path $ServerRoot 'logs';[IO.Directory]::CreateDirectory($LogRoot)|Out-Null
    $script:DdnsWorkerProcess=Start-Process -FilePath $PowerShellExe -ArgumentList @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',('"'+$WorkerPath+'"'),'-ServerRoot',('"'+$ServerRoot+'"')) -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $LogRoot 'ddns-worker.log') -RedirectStandardError (Join-Path $LogRoot 'ddns-worker-error.log') -PassThru
    $script:DdnsWorkerLastLaunch=Get-Date
}

function Complete-DdnsWorker {
    if (-not $script:DdnsWorkerProcess) { return }
    try { $script:DdnsWorkerProcess.Refresh();if(-not $script:DdnsWorkerProcess.HasExited){return} } catch { return }
    $ExitCode=$script:DdnsWorkerProcess.ExitCode;$script:DdnsWorkerProcess.Dispose();$script:DdnsWorkerProcess=$null
    try { Refresh-NetworkAccessSettings;Update-NetworkHeader } catch {}
    if ($ExitCode -ne 0) { Set-Activity 'La mise à jour DDNS automatique a échoué. Ouvre Réseau pour le détail.' }
}

function Update-NetworkHeader {
    $LanIp = 'Indisponible'
    try {
        $Configuration = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
            $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address -and $_.IPv4DefaultGateway
        }) | Select-Object -First 1
        if ($Configuration) { $LanIp = [string]$Configuration.IPv4Address.IPAddress }
    }
    catch { }
    $FriendCommand = Get-FriendCommand
    $PublicIp = 'En attente...'
    $Match = [regex]::Match($FriendCommand,'client\.connect\s+\[?([^\]:]+)\]?:\d+')
    if ($Match.Success -and $Match.Groups[1].Value -ne 'ADRESSE_IP') { $PublicIp = $Match.Groups[1].Value }
    $State = Get-RustRpgServerState
    $Profile = if ($State.Running) { $State.Label + ' - ' + $State.Detail } else { 'Serveur arrete' }
    $Ui.NetworkLanIpText.Text = $LanIp
    $Ui.NetworkPublicIpText.Text = $PublicIp
    $Ui.NetworkFriendText.Text = $FriendCommand
    $Ui.NetworkProfileText.Text = $Profile
    if ($CapturePath) { $Ui.NetworkLanIpText.Text='192.0.2.10';$Ui.NetworkPublicIpText.Text='203.0.113.10';$Ui.NetworkFriendText.Text='client.connect 203.0.113.10:28115' }
}

function Show-NetworkDiagnostics([string]$Json) {
    $Envelope = $Json | ConvertFrom-Json
    $Items = @($Envelope.items)
    if ($CapturePath) {
        $LanRow=@($Items|Where-Object Test -eq 'Adresse LAN'|Select-Object -First 1);$PublicRow=@($Items|Where-Object Test -eq 'Adresse publique'|Select-Object -First 1)
        $LanReal=if($LanRow -and [string]$LanRow.Detail -match '\b(?:\d{1,3}\.){3}\d{1,3}\b'){$Matches[0]}else{''};$PublicReal=if($PublicRow -and [string]$PublicRow.Detail -match '\b(?:\d{1,3}\.){3}\d{1,3}\b'){$Matches[0]}else{''}
        foreach($Item in $Items){foreach($Property in @('Detail','Action')){if($Item.PSObject.Properties.Name-contains$Property){$Value=[string]$Item.$Property;if($LanReal){$Value=$Value.Replace($LanReal,'192.0.2.10')};if($PublicReal){$Value=$Value.Replace($PublicReal,'203.0.113.10')};$Value=[regex]::Replace($Value,'(?<!\d)(?:10(?:\.\d{1,3}){3}|192\.168(?:\.\d{1,3}){2}|172\.(?:1[6-9]|2\d|3[01])(?:\.\d{1,3}){2})(?!\d)','192.0.2.1');$Value=[regex]::Replace($Value,'client\.connect\s+\S+','client.connect 203.0.113.10:28115');$Item.$Property=$Value}}}
    }
    $script:NetworkDiagnosticsCache = $Items
    $Ui.NetworkDiagnosticGrid.ItemsSource = $null
    $Ui.NetworkDiagnosticGrid.ItemsSource = $Items

    $Errors = @($Items | Where-Object Statut -eq 'ERREUR').Count
    $Warnings = @($Items | Where-Object { $_.Statut -in @('ATTENTION','A VERIFIER') }).Count
    $Ok = @($Items | Where-Object Statut -eq 'OK').Count
    $Ui.NetworkSummaryText.Text = "$Ok test(s) OK - $Warnings point(s) a controler - $Errors erreur(s) - diagnostic du $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"

    $Lan = $Items | Where-Object Test -eq 'Adresse LAN' | Select-Object -First 1
    if ($Lan -and $Lan.Detail -match '^(\S+)') { $Ui.NetworkLanIpText.Text = $Matches[1] }
    $Public = $Items | Where-Object Test -eq 'Adresse publique' | Select-Object -First 1
    if ($Public -and $Public.Statut -eq 'OK') { $Ui.NetworkPublicIpText.Text = [string]$Public.Detail }
    $Friend = $Items | Where-Object Test -eq 'Adresse amis' | Select-Object -First 1
    if ($Friend) { $Ui.NetworkFriendText.Text = [string]$Friend.Detail }
    $State = Get-RustRpgServerState
    $Ui.NetworkProfileText.Text = if ($State.Running) { $State.Label + ' - ' + $State.Detail } else { 'Serveur arrete' }
    if ($CapturePath) { $Ui.NetworkLanIpText.Text='192.0.2.10';$Ui.NetworkPublicIpText.Text='203.0.113.10';$Ui.NetworkFriendText.Text='client.connect 203.0.113.10:28115' }
    Set-Activity "Diagnostic reseau termine : $Errors erreur(s), $Warnings point(s) a controler."
}

function Refresh-NetworkDiagnostics([string]$ResponseOverride = '') {
    Update-NetworkHeader
    Refresh-NetworkAccessSettings
    if ($ResponseOverride) {
        Show-NetworkDiagnostics $ResponseOverride
        return
    }
    if ($CapturePath) {
        $Json = [pscustomobject]@{ items = @(Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot -FriendCommand (Get-FriendCommand)) } | ConvertTo-Json -Depth 10 -Compress
        Show-NetworkDiagnostics $Json
        return
    }
    $Ui.NetworkSummaryText.Text = 'Diagnostic en cours : interfaces, IP publique, ports, RCON et pare-feu...'
    Queue-ServerOperation -Operation network -Command (Get-FriendCommand) -Label 'diagnostic reseau complet' -TimeoutMs 20000 -OnSuccess {
        param($Json)
        Show-NetworkDiagnostics $Json
    } -OnError {
        param($Message)
        $Failure = @([pscustomobject]@{ Statut='ERREUR'; Test='Diagnostic reseau'; Detail=$Message; Action='Relance le diagnostic ou ouvre les logs.' })
        $script:NetworkDiagnosticsCache = $Failure
        $Ui.NetworkDiagnosticGrid.ItemsSource = $Failure
        $Ui.NetworkSummaryText.Text = 'Le diagnostic n a pas pu se terminer.'
        Set-Activity "Diagnostic reseau impossible : $Message"
    }
}

function Copy-NetworkReport {
    if ($script:NetworkDiagnosticsCache.Count -eq 0) { throw 'Lance d abord le diagnostic reseau.' }
    $Lines = @(
        'RUST SERVER CONTROL CENTER v12.1.0 - DIAGNOSTIC RESEAU',
        ('Date : ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')),
        ('PC : ' + $env:COMPUTERNAME),
        ('IP LAN : ' + $Ui.NetworkLanIpText.Text),
        ('IP publique : ' + $Ui.NetworkPublicIpText.Text),
        ('Connexion amis : ' + $Ui.NetworkFriendText.Text),
        ''
    )
    foreach ($Item in @($script:NetworkDiagnosticsCache)) {
        $Lines += "[$($Item.Statut)] $($Item.Test)"
        $Lines += "  Detail : $($Item.Detail)"
        if ($Item.Action) { $Lines += "  Action : $($Item.Action)" }
    }
    [Windows.Clipboard]::SetText(($Lines -join "`r`n"))
    Set-Activity 'Rapport reseau copie dans le presse-papiers.'
}

function Open-PluginConfig {
    $Plugin = Get-SelectedPlugin
    if (-not (Test-Path -LiteralPath $Plugin.ConfigPath)) { throw 'Ce plugin ne possede pas encore de fichier de configuration.' }
    Refresh-ConfigFiles -SelectPath $Plugin.ConfigPath
    Select-AdvancedNav -Tab 6
    Load-SelectedConfig
}

function Open-SelectedModeConfig {
    $Capability = $Ui.ModeCapabilityGrid.SelectedItem
    if (-not $Capability) { throw 'Sélectionne un mode.' }
    if (-not (Test-Path -LiteralPath ([string]$Capability.ConfigPath))) {
        throw "Le fichier $($Capability.ConfigName) n'existe pas encore. Démarre le serveur une fois avec ce plugin actif."
    }
    Refresh-ConfigFiles -SelectPath ([string]$Capability.ConfigPath)
    Select-AdvancedNav -Tab 6
    Load-SelectedConfig
}

function Reload-SelectedModePlugin {
    $Capability = $Ui.ModeCapabilityGrid.SelectedItem
    if (-not $Capability) { throw 'Sélectionne un mode.' }
    $Plugin = @($Ui.PluginGrid.ItemsSource | Where-Object FileBase -eq ([string]$Capability.Plugin)) | Select-Object -First 1
    if (-not $Plugin) { throw "Le plugin associé n'est plus installé. Actualise les extensions." }
    $Ui.PluginGrid.SelectedItem = $Plugin
    Reload-SelectedPlugin
}

function Invoke-RconAndDisplay([string]$Command) {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Ui.RconOutput.Text = "> $Command`r`nEnvoi en cours..."
    Queue-ServerOperation -Operation command -Command $Command -Label "RCON : $Command" -OnSuccess {
        param($Response)
        $Ui.RconOutput.Text = "> $Command`r`n`r`n$Response"
        $Ui.RconOutput.ScrollToEnd()
        Set-Activity "Commande RCON executee : $Command"
    }
}

function Refresh-ModeStatus([string]$ResponseOverride = '') {
    if (@($script:ModeCapabilities).Count -eq 0) {
        $Ui.ModeStateOutput.Text = "AUCUN MODE DÉTECTÉ`r`n`r`nInstalle un plugin compatible pour activer cette page."
        return
    }
    # Un plugin present mais DESACTIVE ne repond a aucune commande : interroger
    # le serveur dans ce cas coute un timeout RCON complet par appel, ce qui
    # bloquait le demarrage de l'application. La presence du fichier ne suffit
    # donc pas, il faut que le plugin soit reellement charge.
    if (-not @($script:ModeCapabilities | Where-Object Enabled).Count) {
        $Ui.ModeStateOutput.Text = "MODES INSTALLÉS MAIS DÉSACTIVÉS`r`n`r`nActive au moins un mode dans Mods & Modes pour piloter les parties."
        return
    }
    if (-not (Get-RustRpgServerState).Running) {
        $Ui.ModeStateOutput.Text = "SERVEUR ARRETE`r`n`r`nLance le serveur pour afficher les joueurs, les files et les parties actives."
        return
    }
    if (-not @($script:ModeCapabilities | Where-Object { $_.Id -eq 'competitive' -and $_.Enabled }).Count) {
        $Ui.ModeStateOutput.Text = "APERÇU GLOBAL INDISPONIBLE`r`n`r`nRustGameHub.cs n'est pas installé. Les autres modes restent configurables et leurs actions dédiées restent disponibles."
        return
    }

    # Une seule requete : un RustGameHub recent repond en JSON, un ancien ignore
    # l'argument et renvoie son texte. En utilisation normale elle passe par la
    # file asynchrone ; le mode capture garde une lecture immediate et stable.
    if ($ResponseOverride) {
        $Response = $ResponseOverride
    }
    elseif (-not $CapturePath) {
        Queue-ServerOperation -Operation command -Command 'dashboard.modes json' -Label 'actualisation des modes' -OnSuccess {
            param($Text)
            Refresh-ModeStatus -ResponseOverride $Text
        }
        return
    }
    else {
        $Response = [string](Invoke-BusyAction { Invoke-RustRpgRconCommand -ServerRoot $ServerRoot -Command 'dashboard.modes json' -TimeoutMs 10000 })
    }

    $RewardControls = [ordered]@{
        duel_xp_base = 'DuelXpRewardBox'; duel_coins_base = 'DuelCoinRewardBox'
        tournament_xp = 'TournamentXpRewardBox'; tournament_coins = 'TournamentCoinRewardBox'
        zombie_kill_xp = 'ZombieKillXpRewardBox'; zombie_kill_coins = 'ZombieKillCoinRewardBox'
        wave_coins = 'WaveCoinRewardBox'; zombie_victory_xp = 'ZombieVictoryXpRewardBox'
        zombie_victory_coins = 'ZombieVictoryCoinRewardBox'; mode_xp = 'ModeXpRewardBox'; mode_coins = 'ModeCoinRewardBox'
    }

    $Data = $null
    if ($Response.TrimStart().StartsWith('{')) {
        try { $Data = $Response | ConvertFrom-Json } catch { $Data = $null }
    }

    if ($null -eq $Data) {
        # Repli texte : parsing par motif, comme avant.
        $Ui.ModeStateOutput.Text = $Response
        $Ui.ModeStateOutput.ScrollToHome()
        foreach ($Entry in $RewardControls.GetEnumerator()) {
            $Match = [regex]::Match($Response, ([regex]::Escape([string]$Entry.Key) + '=(\d+)'))
            if ($Match.Success) { $Ui[$Entry.Value].Text = $Match.Groups[1].Value }
        }
        Set-Activity 'Etat des modes actualise (format texte).'
        return
    }

    $Lines = @()
    $PlayerCount = @($Data.players).Count
    $Lines += "JOUEURS CONNECTES : $PlayerCount"
    if ($PlayerCount -gt 0) {
        foreach ($Player in $Data.players) { $Lines += "   - $($Player.name)  [$($Player.steamId)]" }
    }
    else { $Lines += '   aucun joueur connecte' }

    $Running = @($Data.modes | Where-Object { $_.running })
    $Lines += ''
    $Lines += if ($Running.Count -gt 0) { "PARTIES EN COURS : " + (($Running | ForEach-Object { $_.name }) -join ', ') } else { 'PARTIES EN COURS : aucune' }

    foreach ($Mode in $Data.modes) {
        $Lines += ''
        $Marker = if ($Mode.running) { '[EN COURS]' } elseif (-not $Mode.available) { '[INDISPONIBLE]' } else { '[INACTIF]' }
        $Lines += ("{0} {1}" -f $Marker, $Mode.name.ToUpperInvariant())
        # Une cle par ligne : bien plus lisible que la ligne unique d'origine.
        foreach ($Pair in ([regex]::Matches([string]$Mode.status, '(\w+)=(\[[^\]]*\]|\([^\)]*\)|\S*)'))) {
            $Lines += ("   {0,-18} {1}" -f $Pair.Groups[1].Value, $Pair.Groups[2].Value)
        }
    }

    $Ui.ModeStateOutput.Text = $Lines -join "`r`n"
    $Ui.ModeStateOutput.ScrollToHome()

    foreach ($Entry in $RewardControls.GetEnumerator()) {
        $Value = $Data.rewards.($Entry.Key)
        if ($null -ne $Value) { $Ui[$Entry.Value].Text = [string]$Value }
    }
    Set-Activity 'Etat des modes et recompenses actualise.'
}

function Invoke-ModeAdminCommand([string]$Command, [string]$DisruptiveLabel = '') {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    if ($DisruptiveLabel) {
        Invoke-AfterDisruptionCheck -ActionLabel $DisruptiveLabel -Continuation {
            Invoke-ModeAdminCommand -Command $Command
        }
        return
    }
    Queue-ServerOperation -Operation command -Command $Command -Label "action mode : $Command" -OnSuccess {
        param($Response)
        $Ui.ModeStateOutput.Text = "[ACTION] > $Command`r`n$Response`r`n`r`nActualisation de l'etat..."
        $Ui.ModeStateOutput.ScrollToHome()
        Set-Activity "Action mode executee : $Command"
        Refresh-ModeStatus
    }
}

function Get-RewardNumber([string]$ControlName, [string]$Label) {
    $Value = 0
    if (-not [int]::TryParse($Ui[$ControlName].Text.Trim(), [ref]$Value) -or $Value -lt 0 -or $Value -gt 100000) {
        throw "$Label doit etre un nombre entre 0 et 100000."
    }
    return $Value
}

function Save-ModeRewards {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Values = @(
        (Get-RewardNumber 'DuelXpRewardBox' 'XP duel'),
        (Get-RewardNumber 'DuelCoinRewardBox' 'Pieces duel'),
        (Get-RewardNumber 'TournamentXpRewardBox' 'XP tournoi'),
        (Get-RewardNumber 'TournamentCoinRewardBox' 'Pieces tournoi'),
        (Get-RewardNumber 'ZombieKillXpRewardBox' 'XP zombie'),
        (Get-RewardNumber 'ZombieKillCoinRewardBox' 'Pieces zombie'),
        (Get-RewardNumber 'WaveCoinRewardBox' 'Pieces de vague'),
        (Get-RewardNumber 'ZombieVictoryXpRewardBox' 'XP victoire Zombie'),
        (Get-RewardNumber 'ZombieVictoryCoinRewardBox' 'Pieces victoire Zombie'),
        (Get-RewardNumber 'ModeXpRewardBox' 'XP mode competitif'),
        (Get-RewardNumber 'ModeCoinRewardBox' 'Pieces mode competitif')
    )
    $Command = 'rpg.rewards.apply ' + ($Values -join ' ')
    Queue-ServerOperation -Operation command -Command $Command -Label 'application des recompenses des modes' -OnSuccess {
        param($Response)
        Set-Activity 'Recompenses des modes enregistrees et appliquees.'
        Refresh-ModeStatus
    }
}

function Refresh-Players([string]$JsonOverride = '') {
    if (-not (Get-RustRpgServerState).Running) {
        $Ui.PlayerGrid.ItemsSource = $null
        $Ui.PlayerSummaryText.Text = 'Serveur arrete.'
        return
    }
    if ($JsonOverride) {
        $Envelope = $JsonOverride | ConvertFrom-Json
        $Players = @($Envelope.items)
    }
    elseif (-not $CapturePath) {
        Queue-ServerOperation -Operation players -Label 'actualisation des joueurs' -OnSuccess {
            param($Json)
            Refresh-Players -JsonOverride $Json
        }
        return
    }
    else {
        $Players = @(Invoke-BusyAction { Get-RustRpgPlayers -ServerRoot $ServerRoot })
    }
    $Ui.PlayerGrid.ItemsSource = $null
    $Ui.PlayerGrid.ItemsSource = $Players
    $Ui.PlayerSummaryText.Text = if ($Players.Count -eq 0) { 'Aucun joueur connecte.' } else { "$($Players.Count) joueur(s) connecte(s)." }
}

function Refresh-Bans([string]$JsonOverride = '') {
    if (-not (Get-RustRpgServerState).Running) { $Ui.BanGrid.ItemsSource = $null; return }
    if ($JsonOverride) {
        $Envelope = $JsonOverride | ConvertFrom-Json
        $Bans = @($Envelope.items)
    }
    elseif (-not $CapturePath) {
        Queue-ServerOperation -Operation bans -Label 'actualisation des bannissements' -OnSuccess {
            param($Json)
            Refresh-Bans -JsonOverride $Json
        }
        return
    }
    else {
        $Bans = @(Invoke-BusyAction { Get-RustRpgBans -ServerRoot $ServerRoot })
    }
    $Ui.BanGrid.ItemsSource = $null
    $Ui.BanGrid.ItemsSource = $Bans
}

function Refresh-ModerationLog {
    $Entries = @(Get-RustRpgModerationLog -ServerRoot $ServerRoot)
    $Ui.ModerationGrid.ItemsSource = $null
    $Ui.ModerationGrid.ItemsSource = $Entries
}

function Get-SelectedPlayer {
    $Player = $Ui.PlayerGrid.SelectedItem
    if (-not $Player) { throw 'Selectionne un joueur dans la liste.' }
    return $Player
}

function Invoke-PlayerSanction([ValidateSet('kick','ban')][string]$Action) {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Player = Get-SelectedPlayer
    $Reason = $Ui.ModerationReasonBox.Text.Trim()

    $Label = if ($Action -eq 'ban') { 'BANNIR definitivement' } else { 'expulser' }
    $Warning = if ($Action -eq 'ban') { "`n`nLe bannissement est permanent : il faudra le lever a la main." } else { '' }
    if (-not (Confirm-Action ("Confirmer : $Label $($Player.Nom) ?`nSteamID : $($Player.SteamID)`nMotif : " + $(if($Reason){$Reason}else{'aucun'}) + $Warning) 'Sanction')) {
        Set-Activity 'Sanction annulee.'
        return
    }

    $CleanReason = (($Reason -replace '[\r\n]+',' ').Replace('"',"'")).Trim()
    $Command = if ($Action -eq 'ban') { 'ban ' + $Player.SteamID + ' "' + $(if($CleanReason){$CleanReason}else{'Aucun motif precise'}) + '"' } else { 'kick ' + $Player.SteamID + ' "' + $(if($CleanReason){$CleanReason}else{'Aucun motif precise'}) + '"' }
    Queue-ServerOperation -Operation command -Command $Command -Label "$Action de $($Player.Nom)" -OnSuccess {
        param($Response)
        $null = Write-RustRpgModerationLog -ServerRoot $ServerRoot -Action $Action -SteamId $Player.SteamID -PlayerName $Player.Nom -Reason $Reason -Result $Response
        $Ui.ModerationReasonBox.Text = ''
        Refresh-Players
        Refresh-Bans
        Refresh-ModerationLog
        Set-Activity "$Action applique a $($Player.Nom)."
    }
}

function Invoke-PlayerUnban {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Ban = $Ui.BanGrid.SelectedItem
    if (-not $Ban) { throw 'Selectionne un joueur banni.' }
    if (-not (Confirm-Action "Lever le bannissement de $($Ban.SteamID) ?" 'Debannir')) { return }

    $Command = 'unban ' + $Ban.SteamID
    Queue-ServerOperation -Operation command -Command $Command -Label "debannissement de $($Ban.SteamID)" -OnSuccess {
        param($Response)
        $null = Write-RustRpgModerationLog -ServerRoot $ServerRoot -Action 'unban' -SteamId $Ban.SteamID -Result $Response
        Refresh-Bans
        Refresh-ModerationLog
        Set-Activity "Bannissement leve pour $($Ban.SteamID)."
    }
}

function Invoke-PlayerComfort([ValidateSet('heal','free','message')][string]$Action) {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
    $Player = Get-SelectedPlayer

    if ($Action -eq 'heal') {
        Queue-ServerOperation -Operation command -Command ("admin.heal " + $Player.SteamID) -Label "soin de $($Player.Nom)" -OnSuccess {
            param($Response)
            if ($Response -match 'Exception|introuvable') { throw "Le serveur a refuse de soigner $($Player.Nom) : $Response" }
            Set-Activity $Response
        }
        return
    }
    if ($Action -eq 'free') {
        # admin.free ne libere que ce joueur : les parties des autres continuent.
        Queue-ServerOperation -Operation command -Command ("admin.free " + $Player.SteamID) -Label "deblocage de $($Player.Nom)" -OnSuccess {
            param($Response)
            Refresh-Players
            Set-Activity $Response
        }
        return
    }

    $Message = ($Ui.ModerationReasonBox.Text -replace '[\r\n]+',' ').Trim()
    if (-not $Message) { throw 'Saisis le message dans le champ motif.' }
    $CleanMessage = $Message.Replace('"',"'")
    $Command = 'admin.message ' + $Player.SteamID + ' "' + $CleanMessage + '"'
    Queue-ServerOperation -Operation command -Command $Command -Label "message prive a $($Player.Nom)" -OnSuccess {
        param($Response)
        $Ui.ModerationReasonBox.Text = ''
        Set-Activity $Response
    }
}

function Test-RustPluginActive([string]$FileBase) {
    $Context = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
    return Test-Path -LiteralPath (Join-Path $Context.PluginRoot ("plugins\" + $FileBase + '.cs'))
}

function Refresh-Stats([string]$JsonOverride = '', [switch]$FromWorker) {
    # Classements et statistiques possedent tous deux un repli sur disque.
    $Leaderboards = @(Get-RustRpgLeaderboards -ServerRoot $ServerRoot)
    $Ui.LeaderboardGrid.ItemsSource = $null
    $Ui.LeaderboardGrid.ItemsSource = $Leaderboards

    # Sans RustStats charge, "stats.dump json" est une commande inconnue et
    # l'appel part en timeout RCON complet. Les classements viennent du disque
    # et restent affiches, seule la partie collectee est indisponible.
    if (-not $FromWorker -and -not (Test-RustPluginActive 'RustStats')) {
        $Ui.ModeStatsGrid.ItemsSource = $null
        $Ui.PlayerStatsGrid.ItemsSource = $null
        $Ui.StatsSummaryText.Text = 'Le plugin RustStats n''est pas actif : parties et temps de jeu non collectes. Les classements ci-dessous sont lus sur disque.'
        return
    }

    if ($FromWorker) {
        $Stats = if ($JsonOverride) { $JsonOverride | ConvertFrom-Json } else { $null }
    }
    elseif ((Get-RustRpgServerState).Running -and -not $CapturePath) {
        Queue-ServerOperation -Operation stats -Label 'actualisation des statistiques' -OnSuccess {
            param($Json)
            Refresh-Stats -JsonOverride $Json -FromWorker
        }
        return
    }
    else {
        $Stats = Invoke-BusyAction { Get-RustRpgStats -ServerRoot $ServerRoot }
    }
    if (-not $Stats) {
        $Ui.ModeStatsGrid.ItemsSource = $null
        $Ui.PlayerStatsGrid.ItemsSource = $null
        $Ui.StatsSummaryText.Text = 'Aucune donnee RustStats disponible. Classements lus sur disque uniquement.'
        return
    }

    $Modes = @($Stats.modes | ForEach-Object {
        [pscustomobject]@{
            Mode         = $_.nom
            Parties      = $_.parties
            DureeMoyenne = Format-RustRpgDuration ([int]$_.dureeMoyenne)
            PlusLongue   = Format-RustRpgDuration ([int]$_.plusLongue)
            Derniere     = if ($_.derniere) { $_.derniere } else { '-' }
        }
    })
    $Ui.ModeStatsGrid.ItemsSource = $null
    $Ui.ModeStatsGrid.ItemsSource = $Modes

    $script:PlayerStatsCache = @($Stats.joueurs | ForEach-Object {
        [pscustomobject]@{
            Nom       = if ($_.nom) { $_.nom } else { $_.steamId }
            SteamID   = $_.steamId
            Sessions  = $_.sessions
            TempsJeu  = Format-RustRpgDuration ([int]$_.secondesJeu)
            Derniere  = if ($_.derniere) { $_.derniere } else { '-' }
            Premiere  = if ($_.premiere) { $_.premiere } else { '-' }
            Notes     = [string]$_.notes
            Victoires = $_.victoires
        }
    } | Sort-Object -Property @{Expression={$_.Sessions};Descending=$true})

    $Ui.PlayerStatsGrid.ItemsSource = $null
    $Ui.PlayerStatsGrid.ItemsSource = $script:PlayerStatsCache

    $TotalParties = ($Stats.modes | Measure-Object -Property parties -Sum).Sum
    $SourceLabel = if ($Stats.source -eq 'disque') { 'donnees hors ligne' } else { 'direct RCON' }
    $Ui.StatsSummaryText.Text = "Collecte depuis $($Stats.depuis) - $TotalParties partie(s), $(@($Stats.joueurs).Count) joueur(s) connu(s) - $SourceLabel."
}

function Show-PlayerCard {
    $Player = $Ui.PlayerStatsGrid.SelectedItem
    if (-not $Player) { $Ui.PlayerCardText.Text = ''; $Ui.PlayerNoteBox.Text = ''; return }

    $Lines = @()
    $Lines += "JOUEUR    : $($Player.Nom)"
    $Lines += "STEAMID   : $($Player.SteamID)"
    $Lines += "SESSIONS  : $($Player.Sessions)   TEMPS DE JEU : $($Player.TempsJeu)"
    $Lines += "PREMIERE  : $($Player.Premiere)"
    $Lines += "DERNIERE  : $($Player.Derniere)"
    $Lines += ''

    $Wins = @()
    if ($Player.Victoires) {
        foreach ($p in $Player.Victoires.PSObject.Properties) { $Wins += "$($p.Name) : $($p.Value)" }
    }
    $Lines += 'VICTOIRES : ' + $(if ($Wins.Count) { $Wins -join '   ' } else { 'aucune' })

    $Records = @(Get-RustRpgLeaderboards -ServerRoot $ServerRoot | Where-Object SteamID -eq $Player.SteamID)
    $Lines += 'RECORDS   : ' + $(if ($Records.Count) { ($Records | ForEach-Object { "$($_.Classement)=$($_.Valeur)" }) -join '   ' } else { 'aucun' })

    $Sanctions = @(Get-RustRpgModerationLog -ServerRoot $ServerRoot | Where-Object SteamID -eq $Player.SteamID)
    $Lines += ''
    $Lines += "SANCTIONS : $($Sanctions.Count)"
    foreach ($S in ($Sanctions | Select-Object -First 8)) {
        $Lines += "  $($S.Date)  $($S.Action)  $($S.Motif)"
    }

    $Ui.PlayerCardText.Text = $Lines -join "`r`n"
    $Ui.PlayerNoteBox.Text = [string]$Player.Notes
}

function Save-PlayerNote {
    if (-not (Get-RustRpgServerState).Running) { throw "Le serveur doit etre actif pour enregistrer une note." }
    $Player = $Ui.PlayerStatsGrid.SelectedItem
    if (-not $Player) { throw 'Selectionne un joueur.' }
    $Note = (($Ui.PlayerNoteBox.Text -replace '[\r\n]+',' ').Trim()).Replace('"', "'")
    $Command = 'stats.note ' + $Player.SteamID + ' "' + $Note + '"'
    Queue-ServerOperation -Operation command -Command $Command -Label "note de $($Player.Nom)" -OnSuccess {
        param($Response)
        Refresh-Stats
        Set-Activity "Note enregistree pour $($Player.Nom)."
    }
}

function Refresh-LogFiles {
    $Files = @()
    $PluginContext = Get-RustPluginRuntimeContext -ServerRoot $ServerRoot
    foreach ($Directory in @((Join-Path $ServerRoot 'logs'),$PluginContext.LogsRoot)) {
        if (Test-Path -LiteralPath $Directory) {
            $Files += @(Get-ChildItem -LiteralPath $Directory -File -Recurse -ErrorAction SilentlyContinue | Where-Object Extension -in '.log','.txt')
        }
    }
    $Items = @($Files | Sort-Object LastWriteTime -Descending | Select-Object -First 40 | ForEach-Object {
        [pscustomobject]@{ Display = $_.Name + '  -  ' + $_.LastWriteTime.ToString('dd/MM HH:mm'); Path = $_.FullName }
    })
    $Ui.LogFileCombo.ItemsSource = $null
    $Ui.LogFileCombo.DisplayMemberPath = 'Display'
    $Ui.LogFileCombo.ItemsSource = $Items
    if ($Items.Count -gt 0) { $Ui.LogFileCombo.SelectedIndex = 0 }
}

function Load-SelectedLog {
    $Item = $Ui.LogFileCombo.SelectedItem
    if (-not $Item) { $Ui.LogViewer.Text = 'Aucun log disponible.'; return }
    $Ui.LogViewer.Text = (Get-Content -LiteralPath $Item.Path -Tail 600 -ErrorAction Stop) -join "`r`n"
    $Ui.LogViewer.ScrollToEnd()
}

function Start-ControlCenterUpdate([switch]$InstallCarbon,[switch]$InstallOxide) {
    if (Test-ControlCenterUpdateRunning) { throw 'Une installation ou une mise à jour est déjà en cours.' }
    if ((Get-RustRpgServerState).Running) { throw "Arrete le serveur avant la mise a jour." }
    $Path = Join-Path $ServerRoot 'Install-Update.ps1'
    if (-not (Test-Path -LiteralPath $Path)) { throw 'Install-Update.ps1 est introuvable.' }
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $LogDirectory = Join-Path $ServerRoot 'logs'
    New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $LogDirectory "update-$Stamp.log"
    $ErrorPath = Join-Path $LogDirectory "update-$Stamp-error.log"
    $Arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $Path + '"'))
    if ($InstallCarbon) { $Arguments += '-InstallCarbon' }
    if ($InstallOxide) { $Arguments += '-InstallOxide' }
    $Process = Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath -PassThru
    $OperationType = if ($InstallCarbon) { 'CarbonInstall' } elseif ($InstallOxide) { 'OxideInstall' } else { 'Update' }
    $OperationTitle = if ($InstallCarbon) { 'Installation de Carbon' } elseif ($InstallOxide) { "Installation d’Oxide/uMod" } elseif (Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe')) { 'Mise à jour de Rust Dedicated' } else { 'Installation de Rust Dedicated' }
    $RetryAction = if ($InstallCarbon) { 'carbon' } elseif ($InstallOxide) { 'oxide' } else { 'update' }
    $Tracked = New-RustTrackedOperation -ServerRoot $ServerRoot -Type $OperationType -Title $OperationTitle -Stage 'PRÉPARATION' -Detail 'Lancement de la tâche silencieuse...' -RetryAction $RetryAction -CanCancel $true -LogPath $OutputPath -ErrorLogPath $ErrorPath -ProcessId ([int]$Process.Id) -Metadata ([pscustomobject]@{ installCarbon=[bool]$InstallCarbon;installOxide=[bool]$InstallOxide })
    $script:UpdateProgressPulse = 0
    $script:UpdateOperation = [pscustomobject]@{
        Id          = [string]$Tracked.id
        Process    = $Process
        OutputPath = $OutputPath
        ErrorPath  = $ErrorPath
        State      = 'Running'
        Percent    = 1.0
        Stage      = 'PRÉPARATION'
        Detail     = 'Lancement de la mise à jour silencieuse...'
    }
    $script:OperationLastPersistAt = [datetime]::MinValue
    Show-ControlCenterUpdateProgress
    Sync-ControlCenterUpdateOperation -Force
    Update-RuntimeDisplay
}

function New-PluginSdkSettingRow {
    param([Parameter(Mandatory = $true)]$SettingState)
    $Definition = $SettingState.Definition
    $RowBorder = New-Object Windows.Controls.Border
    $RowBorder.BorderBrush = $BrushConverter.ConvertFromString('#302C27')
    $RowBorder.BorderThickness = New-Object Windows.Thickness(0,0,0,1)
    $RowBorder.Padding = New-Object Windows.Thickness(0,9,0,9)

    $Row = New-Object Windows.Controls.Grid
    $Left = New-Object Windows.Controls.ColumnDefinition
    $Left.Width = New-Object Windows.GridLength(1,[Windows.GridUnitType]::Star)
    $Right = New-Object Windows.Controls.ColumnDefinition
    $Right.Width = New-Object Windows.GridLength(145)
    $Row.ColumnDefinitions.Add($Left)
    $Row.ColumnDefinitions.Add($Right)

    $Copy = New-Object Windows.Controls.StackPanel
    $Label = New-Object Windows.Controls.TextBlock
    $Label.Text = [string]$Definition.label
    $Label.FontWeight = [Windows.FontWeights]::SemiBold
    $Label.TextWrapping = [Windows.TextWrapping]::Wrap
    $Copy.Children.Add($Label) | Out-Null
    if ([string]$Definition.description) {
        $Description = New-Object Windows.Controls.TextBlock
        $Description.Text = [string]$Definition.description
        $Description.Foreground = $BrushConverter.ConvertFromString('#8F867D')
        $Description.FontSize = 11
        $Description.Margin = New-Object Windows.Thickness(0,3,12,0)
        $Description.TextWrapping = [Windows.TextWrapping]::Wrap
        $Copy.Children.Add($Description) | Out-Null
    }
    [Windows.Controls.Grid]::SetColumn($Copy,0)
    $Row.Children.Add($Copy) | Out-Null

    switch ([string]$Definition.type) {
        'boolean' {
            $Control = New-Object Windows.Controls.CheckBox
            $Control.IsChecked = [bool]$SettingState.Value
            $Control.Style = $Window.FindResource('WizardCheck')
            $Control.HorizontalAlignment = [Windows.HorizontalAlignment]::Right
            $Control.VerticalAlignment = [Windows.VerticalAlignment]::Center
        }
        'choice' {
            $Control = New-Object Windows.Controls.ComboBox
            $Control.ItemsSource = @($Definition.options)
            $Control.SelectedItem = $SettingState.Value
            $Control.MinWidth = 135
        }
        default {
            $Control = New-Object Windows.Controls.TextBox
            $Control.Text = if ([string]$Definition.type -in @('integer','number')) { [Convert]::ToString($SettingState.Value,[Globalization.CultureInfo]::InvariantCulture) } else { [string]$SettingState.Value }
            $Control.MinWidth = 135
            $Control.VerticalContentAlignment = [Windows.VerticalAlignment]::Center
        }
    }
    $Control.Tag = [string]$Definition.id
    $Control.ToolTip = ([string]$Definition.path + $(if ($SettingState.UsingDefault) { ' · valeur par défaut' } else { ' · valeur enregistrée' }))
    [Windows.Controls.Grid]::SetColumn($Control,1)
    $Row.Children.Add($Control) | Out-Null
    $RowBorder.Child = $Row
    $script:PluginSdkControlMap[[string]$Definition.id] = $Control
    return $RowBorder
}

function Update-PluginSdkInspector {
    $Ui.PluginSdkSettingsPanel.Children.Clear()
    $Ui.PluginSdkActionsPanel.Children.Clear()
    $script:PluginSdkControlMap = @{}
    $Ui.PluginSdkStatusText.Foreground = $BrushConverter.ConvertFromString('#B7ADA2')
    $Plugin = $Ui.PluginGrid.SelectedItem
    if (-not $Plugin) {
        $Ui.PluginSdkTitleText.Text = 'SÉLECTIONNE UNE EXTENSION'
        $Ui.PluginSdkSummaryText.Text = 'Les réglages et actions compatibles apparaîtront ici.'
        $Ui.PluginSdkStatusText.Text = '—'
        $Ui.PluginSdkSaveButton.IsEnabled = $false
        $Ui.PluginSdkOpenConfigButton.IsEnabled = $false
        return
    }
    $Ui.PluginSdkTitleText.Text = $(if ($Plugin.SdkManifest -and [string]$Plugin.SdkManifest.plugin.displayName) { ([string]$Plugin.SdkManifest.plugin.displayName).ToUpperInvariant() } else { ([string]$Plugin.Nom).ToUpperInvariant() })
    $Ui.PluginSdkOpenConfigButton.IsEnabled = [bool]$Plugin.HasConfig
    if (-not $Plugin.HasSdk -or -not $Plugin.SdkManifest) {
        $Ui.PluginSdkSummaryText.Text = 'Plugin détecté sans manifeste SDK. La gestion du fichier, du code source et du JSON complet reste disponible.'
        $Ui.PluginSdkStatusText.Text = [string]$Plugin.TechnicalLine
        $Ui.PluginSdkSaveButton.IsEnabled = $false
        return
    }
    try {
        $State = Get-RustPluginSdkConfigState -ServerRoot $ServerRoot -FileBase ([string]$Plugin.FileBase)
        $Settings = @($State.Settings)
        $Actions = @($Plugin.SdkManifest.actions)
        $Ui.PluginSdkSummaryText.Text = "SDK v$($Plugin.SdkVersion) · $($Settings.Count) réglage(s) · $($Actions.Count) action(s) · manifeste $($Plugin.SdkManifest.ManifestSource)"
        if ($Settings.Count) {
            foreach ($SettingState in $Settings) { $Ui.PluginSdkSettingsPanel.Children.Add((New-PluginSdkSettingRow -SettingState $SettingState)) | Out-Null }
        }
        else {
            $Empty = New-Object Windows.Controls.TextBlock
            $Empty.Text = 'Ce plugin expose des actions, mais aucun réglage de configuration.'
            $Empty.Foreground = $BrushConverter.ConvertFromString('#9B9288')
            $Empty.TextWrapping = [Windows.TextWrapping]::Wrap
            $Ui.PluginSdkSettingsPanel.Children.Add($Empty) | Out-Null
        }
        $CanRun = [string]$Plugin.Etat -eq 'Actif' -and (Get-RustRpgServerState).Running
        foreach ($Action in $Actions) {
            $Button = New-Object Windows.Controls.Button
            $Button.Content = [string]$Action.label
            $Button.Tag = [string]$Action.id
            $Button.Style = $Window.FindResource($(if ([bool]$Action.confirm) { 'DangerButton' } else { 'SmallButton' }))
            $Button.Margin = New-Object Windows.Thickness(0,0,7,7)
            $Button.IsEnabled = $CanRun
            $Button.Add_Click({ param($Sender,$EventArgs) $ClickedActionId = [string]$Sender.Tag; Invoke-UiAction { Invoke-SelectedPluginSdkAction -ActionId $ClickedActionId } })
            $Ui.PluginSdkActionsPanel.Children.Add($Button) | Out-Null
        }
        $Ui.PluginSdkSaveButton.IsEnabled = $Settings.Count -gt 0
        $Ui.PluginSdkStatusText.Text = if ($CanRun) { 'Prêt · les actions seront envoyées par RCON.' } elseif ([string]$Plugin.Etat -ne 'Actif') { 'Active le plugin pour utiliser ses actions.' } else { 'Démarre le serveur pour utiliser les actions RCON.' }
    }
    catch {
        $Ui.PluginSdkSummaryText.Text = 'Le manifeste est reconnu, mais sa configuration ne peut pas être chargée.'
        $Ui.PluginSdkStatusText.Text = $_.Exception.Message
        $Ui.PluginSdkStatusText.Foreground = $BrushConverter.ConvertFromString('#E76A4C')
        $Ui.PluginSdkSaveButton.IsEnabled = $false
    }
}

function Save-SelectedPluginSdkConfiguration {
    $Plugin = Get-SelectedPlugin
    if (-not $Plugin.HasSdk -or $script:PluginSdkControlMap.Count -eq 0) { throw 'Ce plugin ne propose aucun réglage SDK.' }
    $Values = [ordered]@{}
    foreach ($Entry in $script:PluginSdkControlMap.GetEnumerator()) {
        $Control = $Entry.Value
        if ($Control -is [Windows.Controls.CheckBox]) { $Values[$Entry.Key] = [bool]$Control.IsChecked }
        elseif ($Control -is [Windows.Controls.ComboBox]) { $Values[$Entry.Key] = $Control.SelectedItem }
        else { $Values[$Entry.Key] = [string]$Control.Text }
    }
    $Result = Set-RustPluginSdkConfiguration -ServerRoot $ServerRoot -FileBase ([string]$Plugin.FileBase) -Values $Values
    Refresh-Plugins
    $Ui.PluginSdkStatusText.Foreground = $BrushConverter.ConvertFromString('#9FD36F')
    $Ui.PluginSdkStatusText.Text = "$($Result.UpdatedCount) réglage(s) enregistré(s). Utilise RECHARGER pour les appliquer au serveur actif."
    Set-Activity "Configuration SDK enregistrée : $($Plugin.Nom)."
}

function Invoke-SelectedPluginSdkAction {
    param([Parameter(Mandatory = $true)][string]$ActionId)
    $Plugin = Get-SelectedPlugin
    $Action = @($Plugin.SdkManifest.actions | Where-Object { [string]$_.id -eq $ActionId } | Select-Object -First 1)[0]
    if (-not $Action) { throw 'Action SDK introuvable.' }
    if ([string]$Plugin.Etat -ne 'Actif') { throw "Active le plugin avant d’utiliser ses actions." }
    if (-not (Get-RustRpgServerState).Running) { throw "Démarre le serveur avant d’envoyer une action." }
    if ([bool]$Action.confirm -and -not (Confirm-Action "Exécuter $($Action.label) ?`n`nCommande : $($Action.command)" 'Action du plugin')) { return }
    $Ui.PluginSdkStatusText.Foreground = $BrushConverter.ConvertFromString('#EFA45D')
    $Ui.PluginSdkStatusText.Text = "> $($Action.command)`nEnvoi en cours..."
    Queue-ServerOperation -Operation command -Command ([string]$Action.command) -Label ("plugin : " + [string]$Action.label) -OnSuccess {
        param($Response)
        $Ui.PluginSdkStatusText.Foreground = $BrushConverter.ConvertFromString('#9FD36F')
        $Ui.PluginSdkStatusText.Text = "> $($Action.command)`n$Response"
        Set-Activity "Action exécutée : $($Action.label)."
    }
}

function Get-GlobalDiagnosticRows {
    if ($CapturePath -and $CaptureDiagnosticDemo) {
        return @(
            [pscustomobject]@{Status='OK';Category='Installation';Check='Dossier du Control Center';Detail='Emplacement portable valide et accessible.';Action=''},
            [pscustomobject]@{Status='OK';Category='Serveur';Check='Rust Dedicated';Detail='Version 6000.3.15 détectée.';Action=''},
            [pscustomobject]@{Status='OK';Category='Configuration';Check='Profils de serveur';Detail='3 profils, ports et identités valides.';Action=''},
            [pscustomobject]@{Status='OK';Category='Sécurité';Check='Secret RCON';Detail='Présent et longueur correcte.';Action=''},
            [pscustomobject]@{Status='OK';Category='Stockage';Check='Espace disque';Detail='84,2 Go libres.';Action=''},
            [pscustomobject]@{Status='INFO';Category='Extensions';Check='Environnement';Detail='Vanilla : aucun Carbon détecté.';Action='Installer Carbon uniquement si des plugins sont nécessaires.'},
            [pscustomobject]@{Status='OK';Category='Automatisation';Check='Planning';Detail='4 règles, 3 actives.';Action=''},
            [pscustomobject]@{Status='WARNING';Category='Automatisation';Check='Service en arrière-plan';Detail="Non activé ; les règles nécessitent que l'app reste ouverte.";Action='Activation facultative dans Wipes.'},
            [pscustomobject]@{Status='OK';Category='Sauvegardes';Check='Dernière sauvegarde';Detail='Archive ZIP · 168 fichiers vérifiés par SHA256.';Action=''},
            [pscustomobject]@{Status='INFO';Category='Mises à jour';Check='Dépôt GitHub';Detail='Non configuré.';Action='Configurer owner/repository avant publication.'}
        )
    }
    return @(Get-RustControlCenterDiagnostics -ServerRoot $ServerRoot)
}

function Refresh-GlobalDiagnostics {
    $Rows = @(Get-GlobalDiagnosticRows)
    $Ui.GlobalDiagnosticGrid.ItemsSource = $null
    $Ui.GlobalDiagnosticGrid.ItemsSource = $Rows
    $Ok = @($Rows | Where-Object Status -eq 'OK').Count
    $Warnings = @($Rows | Where-Object Status -eq 'WARNING').Count
    $Errors = @($Rows | Where-Object Status -eq 'ERROR').Count
    $Ui.GlobalDiagnosticTotalText.Text = [string]$Rows.Count
    $Ui.GlobalDiagnosticOkText.Text = [string]$Ok
    $Ui.GlobalDiagnosticWarningText.Text = [string]$Warnings
    $Ui.GlobalDiagnosticErrorText.Text = [string]$Errors
    $Ui.GlobalDiagnosticSummaryText.Text = if ($Errors) { "$Errors problème(s) bloquant(s) détecté(s). Consulte les actions conseillées avant de lancer un serveur." } elseif ($Warnings) { "Installation utilisable · $Warnings point(s) à surveiller." } else { 'Tous les contrôles obligatoires sont prêts.' }
    if ($CapturePath -and $CaptureDiagnosticDemo) { $Ui.ReleaseRepositoryBox.Text = 'owner/rust-server-control-center' }
    else {
        $ControlState = Get-RustControlCenterState -ServerRoot $ServerRoot
        $Ui.ReleaseRepositoryBox.Text = [string]$ControlState.releaseRepository
    }
    if (-not $Ui.ReleaseChannelCombo.ItemsSource) { $Ui.ReleaseChannelCombo.DisplayMemberPath='Label';$Ui.ReleaseChannelCombo.ItemsSource=@([pscustomobject]@{Code='stable';Label='STABLE'},[pscustomobject]@{Code='beta';Label='BÊTA'}) }
    $SavedChannel = if ($CapturePath) { 'stable' } else { [string](Get-RustControlCenterState -ServerRoot $ServerRoot).releaseChannel }
    $Ui.ReleaseChannelCombo.SelectedItem = $Ui.ReleaseChannelCombo.ItemsSource | Where-Object Code -eq $SavedChannel | Select-Object -First 1
    $ReleaseManifestPath = Join-Path $ServerRoot 'release-manifest.json'
    $Ui.UpdateSignatureStatusText.Text = 'Release actuelle non signée · intégrité SHA-256 vérifiée.'
    if (Test-Path -LiteralPath $ReleaseManifestPath -PathType Leaf) {
        try {
            $ReleaseManifest = Get-Content -LiteralPath $ReleaseManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($ReleaseManifest.PSObject.Properties.Name -contains 'signing' -and [string]$ReleaseManifest.signing.subject) { $Ui.UpdateSignatureStatusText.Text = "Signature Authenticode vérifiée : $($ReleaseManifest.signing.subject)" }
        } catch { }
    }
    Refresh-ControlCenterUpdateBackups
    Set-Activity "Diagnostic terminé : $Ok prêt(s), $Warnings avertissement(s), $Errors erreur(s)."
}

function Save-ReleaseRepository {
    if ($CapturePath) { throw 'La capture de documentation ne peut pas modifier le dépôt.' }
    $Repository = $Ui.ReleaseRepositoryBox.Text.Trim()
    if ($Repository -and $Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw 'Utilise le format propriétaire/dépôt, par exemple mon-compte/rust-control-center.' }
    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $State.releaseRepository = $Repository
    $State.releaseChannel = if ($Ui.ReleaseChannelCombo.SelectedItem) { [string]$Ui.ReleaseChannelCombo.SelectedItem.Code } else { 'stable' }
    $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    $Ui.ReleaseUpdateStatusText.Text = if ($Repository) { "Dépôt enregistré : $Repository · canal $($State.releaseChannel)." } else { 'Mises à jour GitHub désactivées.' }
    Refresh-GlobalDiagnostics
}

function Check-ControlCenterUpdate {
    if ($CapturePath) { throw 'La capture de documentation ne peut pas interroger GitHub.' }
    $Repository = $Ui.ReleaseRepositoryBox.Text.Trim()
    if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw "Configure d'abord un dépôt GitHub au format propriétaire/dépôt." }
    $Updater = Join-Path $ServerRoot 'Update-ControlCenter.ps1'
    if (-not (Test-Path -LiteralPath $Updater)) { throw 'Update-ControlCenter.ps1 est introuvable.' }
    $Ui.ReleaseUpdateStatusText.Text = 'Recherche de la dernière release GitHub...'
    $Result = & $Updater -ServerRoot $ServerRoot -Repository $Repository -CheckOnly
    $Ui.ReleaseUpdateStatusText.Text = if ($Result.UpdateAvailable) { "Mise à jour disponible : $($Result.CurrentVersion) → $($Result.LatestVersion)." } else { "Control Center à jour : $($Result.CurrentVersion)." }
    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $State.lastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
    $State.lastAvailableVersion = if ($Result.UpdateAvailable) { [string]$Result.LatestVersion } else { '' }
    $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    Show-Info $Ui.ReleaseUpdateStatusText.Text
}

function Refresh-ControlCenterUpdateBackups {
    $Updater = Join-Path $ServerRoot 'Update-ControlCenter.ps1'
    $Rows = @(& $Updater -ServerRoot $ServerRoot -ListBackups | ForEach-Object {
        $Created = '-';try{$Created=[datetime]::Parse([string]$_.CreatedUtc).ToLocalTime().ToString('dd/MM/yyyy HH:mm')}catch{}
        [pscustomobject]@{Display=("v{0} · {1}" -f [string]$_.PreviousVersion,$Created);Path=[string]$_.Path;PreviousVersion=[string]$_.PreviousVersion;TargetVersion=[string]$_.TargetVersion}
    })
    $Ui.UpdateBackupCombo.ItemsSource = $null
    $Ui.UpdateBackupCombo.DisplayMemberPath = 'Display'
    $Ui.UpdateBackupCombo.ItemsSource = $Rows
    if ($Rows.Count) { $Ui.UpdateBackupCombo.SelectedIndex = 0 }
    $Ui.RestoreControlCenterVersionButton.IsEnabled = $Rows.Count -gt 0
}

function Restore-ControlCenterVersion {
    if ($CapturePath) { throw 'Restauration désactivée pendant une capture.' }
    $Backup = $Ui.UpdateBackupCombo.SelectedItem
    if (-not $Backup) { throw 'Aucune version précédente disponible.' }
    if ((Get-RustRpgServerState).Running) { throw 'Arrête Rust avant de restaurer le Control Center.' }
    if (-not (Confirm-Action "Revenir à la version $($Backup.PreviousVersion) ?`n`nLe Control Center va se fermer, restaurer uniquement ses fichiers puis redémarrer. Les profils, mondes et sauvegardes restent inchangés." 'Restaurer une version')) { return }
    $Updater = Join-Path $ServerRoot 'Update-ControlCenter.ps1'
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $LogRoot = Join-Path $ServerRoot 'logs';[IO.Directory]::CreateDirectory($LogRoot)|Out-Null
    $Stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$OutputPath=Join-Path $LogRoot "control-center-restore-$Stamp.log";$ErrorPath=Join-Path $LogRoot "control-center-restore-$Stamp-error.log"
    $Arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"'+$Updater+'"'),'-ServerRoot',('"'+$ServerRoot+'"'),'-RestoreBackup',('"'+[string]$Backup.Path+'"'),'-Relaunch')
    Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath | Out-Null
    $Window.Close()
}

function Start-AutomaticControlCenterUpdateCheck {
    if ($CapturePath -or $script:AutomaticUpdateCheckProcess) { return }
    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $Repository = [string]$State.releaseRepository
    if (-not [bool]$State.automaticUpdateCheck -or $Repository -notmatch '^[^/\s]+/[^/\s]+$') { return }
    try { if (([datetime]::UtcNow - [datetime]::Parse([string]$State.lastUpdateCheckUtc).ToUniversalTime()) -lt [TimeSpan]::FromHours(6)) { return } } catch {}
    $ResultPath = Join-Path $ServerRoot 'data\update-check-result.json'
    if (Test-Path -LiteralPath $ResultPath -PathType Leaf) { Remove-Item -LiteralPath $ResultPath -Force }
    $Updater=Join-Path $ServerRoot 'Update-ControlCenter.ps1';$PowerShellExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $Arguments=@('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',('"'+$Updater+'"'),'-ServerRoot',('"'+$ServerRoot+'"'),'-Repository',$Repository,'-CheckOnly','-ResultPath',('"'+$ResultPath+'"'))
    $script:AutomaticUpdateCheckResultPath=$ResultPath
    $script:AutomaticUpdateCheckProcess=Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -PassThru
}

function Complete-AutomaticControlCenterUpdateCheck {
    if (-not $script:AutomaticUpdateCheckProcess) { return }
    try { $script:AutomaticUpdateCheckProcess.Refresh();if(-not$script:AutomaticUpdateCheckProcess.HasExited){return} } catch { return }
    $script:AutomaticUpdateCheckProcess=$null
    if (-not (Test-Path -LiteralPath $script:AutomaticUpdateCheckResultPath -PathType Leaf)) { return }
    try { $Result=Get-Content -LiteralPath $script:AutomaticUpdateCheckResultPath -Raw -Encoding UTF8|ConvertFrom-Json } catch { return }
    $State=Get-RustControlCenterState -ServerRoot $ServerRoot;$PreviousNotice=[string]$State.lastAvailableVersion;$State.lastUpdateCheckUtc=[datetime]::UtcNow.ToString('o');$State.lastAvailableVersion=if([bool]$Result.UpdateAvailable){[string]$Result.LatestVersion}else{''};$null=Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    $Ui.ReleaseUpdateStatusText.Text=if([bool]$Result.UpdateAvailable){"Mise à jour disponible : $($Result.CurrentVersion) → $($Result.LatestVersion)."}else{"Control Center à jour : $($Result.CurrentVersion)."}
    if ([bool]$Result.UpdateAvailable -and $PreviousNotice -ne [string]$Result.LatestVersion) {
        Initialize-OperationNotifications
        if ($script:OperationNotifyIcon) {$script:OperationNotifyIcon.BalloonTipTitle='Mise à jour disponible';$script:OperationNotifyIcon.BalloonTipText="Rust Server Control Center $($Result.LatestVersion) est disponible.";$script:OperationNotifyIcon.BalloonTipIcon=[Windows.Forms.ToolTipIcon]::Info;$script:OperationNotifyIcon.ShowBalloonTip(9000)}
    }
}

function Start-ControlCenterSelfUpdate {
    if ($CapturePath) { throw 'La capture de documentation ne peut pas installer une mise à jour.' }
    $Repository = $Ui.ReleaseRepositoryBox.Text.Trim()
    if ($Repository -notmatch '^[^/\s]+/[^/\s]+$') { throw "Configure d'abord un dépôt GitHub au format propriétaire/dépôt." }
    if ((Get-RustRpgServerState).Running) { throw "Arrête Rust avant de mettre à jour le Control Center." }
    if (-not (Confirm-Action "Le Control Center va se fermer, télécharger la dernière release, vérifier ses sommes SHA256 puis redémarrer.`n`nTes profils, mondes, secrets et sauvegardes seront conservés.`n`nContinuer ?" 'Mettre à jour le Control Center')) { return }
    $Updater = Join-Path $ServerRoot 'Update-ControlCenter.ps1'
    $PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $LogRoot = Join-Path $ServerRoot 'logs'
    [IO.Directory]::CreateDirectory($LogRoot) | Out-Null
    $Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $OutputPath = Join-Path $LogRoot "control-center-update-$Stamp.log"
    $ErrorPath = Join-Path $LogRoot "control-center-update-$Stamp-error.log"
    $Arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + $Updater + '"'),'-ServerRoot',('"' + $ServerRoot + '"'),'-Repository',$Repository,'-Relaunch')
    Start-Process -FilePath $PowerShellExe -ArgumentList $Arguments -WorkingDirectory $ServerRoot -WindowStyle Hidden -RedirectStandardOutput $OutputPath -RedirectStandardError $ErrorPath | Out-Null
    $Window.Close()
}

function Repair-GlobalDiagnostics {
    if ($CapturePath) { throw "La capture de documentation ne peut pas réparer l'installation." }
    if (-not (Confirm-Action "La réparation sûre va créer les dossiers manquants, migrer les fichiers de données et compléter les configurations absentes.`n`nElle ne touche ni au pare-feu, ni au routeur, ni aux mondes Rust.`n`nContinuer ?" 'Réparation sûre')) { return }
    $Result = Repair-RustControlCenterSafeIssues -ServerRoot $ServerRoot
    Refresh-GlobalDiagnostics
    Show-Info ("Réparation terminée.`n`n" + $Result.Detail)
}

function Invoke-RustGuidedRepair([string]$RepairCode) {
    if (-not $RepairCode) { throw "Aucune réparation automatique n'est associée à cette ligne." }
    if ($CapturePath) { throw 'Les réparations sont désactivées pendant une capture de documentation.' }
    switch ($RepairCode) {
        'SafeRepair' { Repair-GlobalDiagnostics; return }
        'ServerUpdate' { Start-ServerUpdate; return }
        'GenerateRconSecret' {
            if (-not (Confirm-Action "Le secret RCON va être remplacé. L’ancien fichier sera sauvegardé localement et toutes les instances doivent être arrêtées.`n`nContinuer ?" 'Nouveau secret RCON')) { return }
            $Result = New-RustRconSecret -ServerRoot $ServerRoot
            Refresh-GlobalDiagnostics
            Show-Info ("Nouveau secret RCON généré localement.`n`nLongueur : {0} caractères`nSauvegarde précédente : {1}" -f $Result.Length,$(if($Result.BackupPath){$Result.BackupPath}else{'aucune'}))
            return
        }
        'CreateBackup' {
            if (@(Get-RustRpgServerProcesses -ServerRoot $ServerRoot).Count) { throw 'Arrête toutes les instances Rust avant cette première sauvegarde guidée.' }
            $Instance = Get-RustServerInstance -ServerRoot $ServerRoot
            if (-not $Instance) { throw 'Aucune instance sélectionnée.' }
            $Path = New-RustServerBackup -ServerRoot $ServerRoot -Identity ([string]$Instance.identity)
            Refresh-Backups
            Refresh-GlobalDiagnostics
            Show-Info "Sauvegarde vérifiable créée :`n`n$Path"
            return
        }
        'OpenIsolation' { Open-ControlCenterTab 1; return }
        'OpenInstances' { Open-ControlCenterTab 1; return }
        'OpenSupervision' { Open-ControlCenterTab 19; Refresh-Supervision; return }
        'OpenRemote' { Open-ControlCenterTab 20; Refresh-RemoteAccess; return }
        'OpenOperations' { Open-ControlCenterTab 14; return }
        'OpenFirewall' { Start-Process control.exe '/name Microsoft.WindowsFirewall'; return }
        'OpenTaskManager' { Start-Process taskmgr.exe; return }
        'OpenStorageSettings' { Start-Process 'ms-settings:storagesense'; return }
        'OpenNetworkSettings' { Start-Process 'ms-settings:network-status'; return }
        'ReinstallPackage' {
            Show-Info 'Le lanceur fait partie du package standalone. Réinstalle la dernière archive dans le même dossier : les données persistantes seront conservées.'
            return
        }
        default { throw "Action guidée inconnue : $RepairCode" }
    }
}

function Repair-SelectedGlobalDiagnostic {
    $Row = $Ui.GlobalDiagnosticGrid.SelectedItem
    if (-not $Row) { throw "Sélectionne d'abord une ligne du diagnostic." }
    Invoke-RustGuidedRepair -RepairCode ([string]$Row.RepairCode)
}

function Refresh-HostHealth {
    $Ui.HostHealthSummaryText.Text = 'Analyse des ressources et des cartes réseau…'
    $Window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)
    $Snapshot = Get-RustHostHealthSnapshot -ServerRoot $ServerRoot
    $Ui.HostHealthCpuText.Text = "$($Snapshot.CpuPercent) %"
    $Ui.HostHealthRamText.Text = Format-RustByteSize ([long]$Snapshot.FreeMemoryBytes)
    $Ui.HostHealthDiskText.Text = Format-RustByteSize ([long]$Snapshot.DiskFreeBytes)
    $Ui.HostHealthCapacityText.Text = "$($Snapshot.SafeAdditionalInstances) +"
    $Ui.HostHealthCapacityDetailText.Text = [string]$Snapshot.CapacityDetail
    $Ui.HostHealthGrid.ItemsSource = $null
    $Ui.HostHealthGrid.ItemsSource = @($Snapshot.Rows)
    $Ui.HostHealthAdapterGrid.ItemsSource = $null
    $Ui.HostHealthAdapterGrid.ItemsSource = @($Snapshot.Adapters)
    $Errors = @($Snapshot.Rows | Where-Object Status -eq 'ERROR').Count
    $Warnings = @($Snapshot.Rows | Where-Object Status -eq 'WARNING').Count
    $Ui.HostHealthSummaryText.Text = if ($Errors) {
        "$Errors point(s) bloquant(s) · $Warnings avertissement(s). Corrige-les avant un lancement multi-instance."
    }
    elseif ($Warnings) {
        "PC utilisable · $Warnings avertissement(s) à vérifier avant une charge importante."
    }
    else {
        "PC prêt · $($Snapshot.ConfiguredInstances) serveur(s) configuré(s), $($Snapshot.RustProcessCount) processus Rust actif(s)."
    }
    Set-Activity "Santé du PC actualisée : CPU $($Snapshot.CpuPercent) %, capacité estimée $($Snapshot.SafeAdditionalInstances) instance(s) supplémentaire(s)."
}

function Repair-SelectedHostHealth {
    $Row = $Ui.HostHealthGrid.SelectedItem
    if (-not $Row) { throw "Sélectionne d'abord une ligne de la préparation du PC." }
    Invoke-RustGuidedRepair -RepairCode ([string]$Row.RepairCode)
}

function Export-GlobalDiagnostics {
    if ($CapturePath) { throw 'Export indisponible pendant une capture.' }
    $Dialog = New-Object Microsoft.Win32.SaveFileDialog
    $Dialog.Title = 'Exporter le diagnostic'
    $Dialog.Filter = 'Rapport JSON (*.json)|*.json|Rapport texte (*.txt)|*.txt'
    $Dialog.FileName = 'rust-control-center-diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'
    if (-not $Dialog.ShowDialog($Window)) { return }
    $Path = Export-RustControlCenterDiagnostics -ServerRoot $ServerRoot -OutputPath $Dialog.FileName
    Set-Activity "Diagnostic exporté : $Path"
}

function Open-Onboarding {
    $script:WizardNavigationGuard = $true
    try { $Ui.MainTabs.SelectedIndex = 18 }
    finally { $script:WizardNavigationGuard = $false }
    Refresh-Onboarding
}

function Set-OnboardingRepairState {
    param([string]$RepairCode='',[string]$Detail='')
    $script:OnboardingRepairCode = $RepairCode
    $script:OnboardingRepairDetail = $Detail
    $Available = [bool]$RepairCode
    $Ui.OnboardingRepairButton.Visibility = if ($Available) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $Ui.OnboardingRepairButton.IsEnabled = $Available
    $Ui.OnboardingRepairButton.ToolTip = if ($Detail) { $Detail } else { $null }
}

function Invoke-OnboardingRepair {
    $RepairCode = [string]$script:OnboardingRepairCode
    if (-not $RepairCode) { throw 'Aucune réparation nécessaire ou disponible pour le moment.' }
    switch ($RepairCode) {
        'ServerUpdate' {
            if (-not (Confirm-Action "Rust Dedicated est absent ou incomplet.`n`nTélécharger et vérifier le serveur maintenant ? Cette opération peut prendre plusieurs minutes et utiliser plusieurs gigaoctets." 'Installer ou réparer Rust Dedicated')) { return }
            Start-OnboardingInstallation
            return
        }
        'OpenNetworkPage' {
            if ($script:InterfaceMode -eq 'simple') { Apply-InterfaceMode -Mode advanced }
            Select-AdvancedNav -Tab 9
            $Ui.MainTabs.SelectedIndex = 9
            Refresh-NetworkDiagnostics
            Set-Activity 'Diagnostic réseau ouvert sur les actions à effectuer.'
            return
        }
        'OpenHostHealth' {
            if ($script:InterfaceMode -eq 'simple') { Apply-InterfaceMode -Mode advanced }
            Select-AdvancedNav -Tab 22
            $Ui.MainTabs.SelectedIndex = 22
            Refresh-HostHealth
            return
        }
        default { Invoke-RustGuidedRepair -RepairCode $RepairCode }
    }
}

function Refresh-Onboarding {
    $HealthErrors = 0
    $HealthWarnings = 0
    $Health = $null
    if ($CapturePath -and $CaptureOnboardingDemo) {
        $RustInstalled = $false
        $ProfileCount = 0
        $TaskInstalled = $false
        $Environment = [pscustomobject]@{Id='vanilla';Label='VANILLA';Installed=$false}
        $Ui.OnboardingAppStatusText.Text = 'CPU 8 cœurs logiques · RAM 32 Go · disque libre 180 Go'
        $Ui.OnboardingHardwareStatusText.Text = 'COMPATIBLE'
        $Ui.OnboardingHardwareStatusText.Foreground = $BrushConverter.ConvertFromString('#72D79B')
    }
    else {
        $RustInstalled = Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe') -PathType Leaf
        try { $ProfileCount = @(Get-RustServerInstances -ServerRoot $ServerRoot).Count } catch { $ProfileCount = 0 }
        $TaskInstalled = (Get-RustMaintenanceTaskStatus -ServerRoot $ServerRoot).Installed
        $Environment = Get-DisplayedEnvironment
        $Health = Get-RustHostHealthSnapshot -ServerRoot $ServerRoot
        $HealthErrors = @($Health.Rows | Where-Object Status -eq 'ERROR').Count
        $HealthWarnings = @($Health.Rows | Where-Object Status -eq 'WARNING').Count
        $Ui.OnboardingAppStatusText.Text = "CPU $([Environment]::ProcessorCount) cœurs logiques · RAM $(Format-RustByteSize ([long]$Health.TotalMemoryBytes)) · disque libre $(Format-RustByteSize ([long]$Health.DiskFreeBytes))"
        $Ui.OnboardingHardwareStatusText.Text = if ($HealthErrors) { 'À CORRIGER' } elseif ($HealthWarnings) { 'UTILISABLE' } else { 'COMPATIBLE' }
        $Ui.OnboardingHardwareStatusText.Foreground = $BrushConverter.ConvertFromString($(if($HealthErrors){'#E46A50'}elseif($HealthWarnings){'#E7A84D'}else{'#72D79B'}))
    }
    $State = Get-RustControlCenterState -ServerRoot $ServerRoot
    $Preference = if ($Environment.Installed) { [string]$Environment.Id } elseif ([string]$State.preferredEnvironment -in @('vanilla','carbon','oxide')) { [string]$State.preferredEnvironment } else { 'vanilla' }
    $Ui.OnboardingVanillaRadio.IsChecked = $Preference -eq 'vanilla'
    $Ui.OnboardingCarbonRadio.IsChecked = $Preference -eq 'carbon'
    $Ui.OnboardingOxideRadio.IsChecked = $Preference -eq 'oxide'
    Update-OnboardingEnvironmentDescription -NoSave
    $Ui.OnboardingServerStatusText.Text = if ($RustInstalled) { 'Rust Dedicated est installé et prêt à être mis à jour.' } else { "Rust Dedicated n'est pas encore installé." }
    $Ui.OnboardingProfilesStatusText.Text = if ($ProfileCount) { "$ProfileCount profil(s) disponible(s). Tu peux en créer d'autres à tout moment." } else { 'Aucun profil : crée ton premier serveur local ou pour tes amis.' }
    $Ui.OnboardingAutomationStatusText.Text = if ($TaskInstalled) { 'Service actif : les sauvegardes et wipes planifiés fonctionneront app fermée.' } else { "Facultatif : sans service, les règles fonctionnent lorsque l'application reste ouverte." }
    $Ui.OnboardingInstallButton.Content = if ($RustInstalled) { 'METTRE À JOUR' } else { 'INSTALLER RUST DEDICATED' }
    $Ui.OnboardingBackgroundButton.Content = if ($TaskInstalled) { 'SERVICE ACTIF' } else { 'ACTIVER EN ARRIÈRE-PLAN' }
    $Ui.OnboardingBackgroundButton.IsEnabled = -not $TaskInstalled
    if (-not $RustInstalled) {
        Set-OnboardingRepairState -RepairCode 'ServerUpdate' -Detail 'Télécharge Rust Dedicated et répare une installation incomplète.'
    }
    elseif ($HealthErrors) {
        $HealthRepair = @($Health.Rows | Where-Object { $_.Status -eq 'ERROR' -and [string]$_.RepairCode } | Select-Object -First 1)
        if ($HealthRepair.Count) { Set-OnboardingRepairState -RepairCode ([string]$HealthRepair[0].RepairCode) -Detail ([string]$HealthRepair[0].Action) }
        else { Set-OnboardingRepairState -RepairCode 'OpenHostHealth' -Detail 'Ouvre la santé du PC pour corriger le blocage matériel.' }
    }
    else { Set-OnboardingRepairState }
}

function Get-OnboardingEnvironmentChoice {
    if ([bool]$Ui.OnboardingCarbonRadio.IsChecked) { return 'carbon' }
    if ([bool]$Ui.OnboardingOxideRadio.IsChecked) { return 'oxide' }
    return 'vanilla'
}

function Update-OnboardingEnvironmentDescription([switch]$NoSave) {
    $Choice = Get-OnboardingEnvironmentChoice
    $Ui.OnboardingEnvironmentStatusText.Text = switch ($Choice) {
        'carbon' { "Carbon : recommandé pour les plugins modernes et les modes fournis avec l’application." }
        'oxide' { 'Oxide/uMod : compatible avec le vaste catalogue historique de plugins Rust.' }
        default { 'Vanilla : expérience Rust officielle, sans framework de plugins.' }
    }
    if (-not $NoSave -and -not $CapturePath) {
        $State = Get-RustControlCenterState -ServerRoot $ServerRoot
        $State.preferredEnvironment = $Choice
        $null = Save-RustControlCenterState -ServerRoot $ServerRoot -State $State
    }
}

function Start-OnboardingInstallation {
    $Choice = Get-OnboardingEnvironmentChoice
    if ($Choice -eq 'carbon') { Start-ControlCenterUpdate -InstallCarbon }
    elseif ($Choice -eq 'oxide') { Start-ControlCenterUpdate -InstallOxide }
    else { Start-ControlCenterUpdate }
    Set-Activity "Installation silencieuse de Rust Dedicated · environnement $($Choice.ToUpperInvariant())."
}

function Test-OnboardingNetwork {
    $Ui.OnboardingNetworkStatusText.Text = 'Diagnostic réseau en cours…'
    $Window.Dispatcher.Invoke([action]{},[Windows.Threading.DispatcherPriority]::Background)
    $Rows = @(Get-RustRpgNetworkDiagnostics -ServerRoot $ServerRoot)
    $Errors = @($Rows | Where-Object Statut -eq 'ERREUR').Count
    $Warnings = @($Rows | Where-Object Statut -eq 'ATTENTION').Count
    $Ui.OnboardingNetworkStatusText.Text = if ($Errors) { "$Errors erreur(s) · $Warnings avertissement(s). Ouvre Réseau & ports pour les détails." } elseif ($Warnings) { "Connexion locale prête · $Warnings point(s) à vérifier pour Internet." } else { 'Connexion locale, LAN et ports vérifiés.' }
    $Ui.OnboardingNetworkStatusText.Foreground = $BrushConverter.ConvertFromString($(if($Errors){'#E46A50'}elseif($Warnings){'#E7A84D'}else{'#72D79B'}))
    if (($Errors -or $Warnings) -and (Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe') -PathType Leaf)) { Set-OnboardingRepairState -RepairCode 'OpenNetworkPage' -Detail 'Ouvre les tests détaillés, le pare-feu et les instructions routeur.' }
    elseif (-not $Errors -and -not $Warnings -and (Test-Path -LiteralPath (Join-Path $ServerRoot 'server\RustDedicated.exe') -PathType Leaf)) { Set-OnboardingRepairState }
    Set-Activity 'Diagnostic réseau de première installation terminé.'
}

function Complete-Onboarding {
    if ($CapturePath) { throw 'La capture de documentation ne peut pas modifier la configuration.' }
    $null = Set-RustOnboardingState -ServerRoot $ServerRoot -Completed $true -Dismissed $false
    Open-ControlCenterTab 0
    Set-Activity 'Configuration initiale terminée. Le Control Center est prêt.'
}

function Dismiss-Onboarding {
    if ($CapturePath) { Open-ControlCenterTab 0; return }
    $null = Set-RustOnboardingState -ServerRoot $ServerRoot -Completed $false -Dismissed $true
    Open-ControlCenterTab 0
    Set-Activity 'Assistant fermé. Tu peux le rouvrir avec Aide & premiers pas.'
}

function Start-ServerUpdate {
    Start-ControlCenterUpdate
    Set-Activity "Mise à jour silencieuse lancée. L'environnement actuel sera conservé."
}

function Start-CarbonInstall {
    if (-not (Confirm-Action "Installer Carbon sur cette installation ?`n`nLe serveur Rust sera d'abord mis à jour. Aucun plugin de mode ne sera ajouté automatiquement." 'Installer Carbon')) { return }
    Start-ControlCenterUpdate -InstallCarbon
    Set-Activity 'Installation silencieuse de Carbon lancée. Consulte les logs de mise à jour pour suivre la progression.'
}

function Start-OxideInstall {
    if (-not (Confirm-Action "Installer Oxide/uMod sur cette installation ?`n`nLe serveur Rust sera d'abord mis à jour. Aucun plugin de mode ne sera ajouté automatiquement." 'Installer Oxide/uMod')) { return }
    Start-ControlCenterUpdate -InstallOxide
    Set-Activity "Installation silencieuse d’Oxide/uMod lancée. Consulte les logs de mise à jour pour suivre la progression."
}

$script:MigrationReport = if ($CapturePath) { [pscustomobject]@{Changed=$false;Changes=@();CurrentSchema=3} } else { Invoke-RustControlCenterMigrations -ServerRoot $ServerRoot }
$InitialCatalog = Get-RustInstanceCatalog -ServerRoot $ServerRoot
foreach ($InitialInstance in @($InitialCatalog.instances)) { $null = Initialize-RustInstanceStorage -ServerRoot $ServerRoot -Instance $InitialInstance }
$Ui.LanguageCombo.DisplayMemberPath = 'Label'
$Ui.LanguageCombo.SelectedValuePath = 'Code'
$Ui.LanguageCombo.ItemsSource = @(
    [pscustomobject]@{ Code='fr-FR'; Label='Français' },
    [pscustomobject]@{ Code='en-US'; Label='English' }
)
$InitialLanguage=if($CaptureLanguage){$CaptureLanguage}else{[string]$InitialCatalog.language}
$Ui.LanguageCombo.SelectedValue = $InitialLanguage
Apply-ControlCenterLanguage -Code $InitialLanguage -NoSave
$InitialUiMode = if ($CaptureUiMode) { $CaptureUiMode } elseif ($InitialCatalog.PSObject.Properties.Name -contains 'uiMode' -and [string]$InitialCatalog.uiMode -eq 'advanced') { 'advanced' } else { 'simple' }
Apply-InterfaceMode -Mode $InitialUiMode -NoSave
Refresh-InstanceSelectors
$Ui.MapTypeCombo.DisplayMemberPath='Label'
$Ui.MapTypeCombo.SelectedValuePath='Code'
$Ui.MapTypeCombo.ItemsSource = @([pscustomobject]@{Code='Procedurale';Label=if($script:CurrentUiLanguage-eq'en-US'){'Procedural'}else{'Procédurale'}},[pscustomobject]@{Code='Custom URL';Label='Custom URL'})
$Ui.MapTypeCombo.SelectedValue = 'Procedurale'
$Ui.MapSizeCombo.ItemsSource = @(1000,1500,2000,2500,3000,3500,4000,4500,5000,5500,6000)
$Ui.MapSizeCombo.SelectedItem = 2000
$Ui.ScheduleActionCombo.DisplayMemberPath = 'Label'
$Ui.ScheduleActionCombo.SelectedValuePath = 'Code'
$Ui.ScheduleActionCombo.ItemsSource = @(
    [pscustomobject]@{ Code='Backup'; Label='Sauvegarde complète' },
    [pscustomobject]@{ Code='MapWipe'; Label='Wipe carte' },
    [pscustomobject]@{ Code='FullWipe'; Label='Full wipe' }
)
$Ui.ScheduleActionCombo.SelectedValue = 'Backup'
$Ui.ScheduleRecurrenceCombo.DisplayMemberPath = 'Label'
$Ui.ScheduleRecurrenceCombo.SelectedValuePath = 'Code'
$Ui.ScheduleRecurrenceCombo.ItemsSource = @(
    [pscustomobject]@{ Code='Daily'; Label='Chaque jour' },
    [pscustomobject]@{ Code='Weekly'; Label='Chaque semaine' },
    [pscustomobject]@{ Code='Interval'; Label='Toutes les X heures' }
)
$Ui.ScheduleRecurrenceCombo.SelectedValue = 'Weekly'
$Ui.ScheduleDayCombo.DisplayMemberPath = 'Label'
$Ui.ScheduleDayCombo.SelectedValuePath = 'Code'
$Ui.ScheduleDayCombo.ItemsSource = @(
    [pscustomobject]@{ Code='Monday'; Label='Lundi' },
    [pscustomobject]@{ Code='Tuesday'; Label='Mardi' },
    [pscustomobject]@{ Code='Wednesday'; Label='Mercredi' },
    [pscustomobject]@{ Code='Thursday'; Label='Jeudi' },
    [pscustomobject]@{ Code='Friday'; Label='Vendredi' },
    [pscustomobject]@{ Code='Saturday'; Label='Samedi' },
    [pscustomobject]@{ Code='Sunday'; Label='Dimanche' }
)
$Ui.ScheduleDayCombo.SelectedValue = 'Thursday'
$Ui.SimpleModsCategoryCombo.ItemsSource = @('Toutes les catégories','Modes de jeu','Gameplay','Économie','Administration','Utilitaires','Autres')
$Ui.SimpleModsCategoryCombo.SelectedIndex = 0
$Ui.SimpleModsStateCombo.ItemsSource = @('Tous les états','Actifs','Désactivés','À vérifier')
$Ui.SimpleModsStateCombo.SelectedIndex = 0
$Ui.InstanceIsolationCombo.DisplayMemberPath='Label'
$Ui.InstanceIsolationCombo.SelectedValuePath='Code'
$Ui.InstanceIsolationCombo.ItemsSource=@([pscustomobject]@{Code='shared';Label='Runtime partagé (vanilla / 1 Carbon)'},[pscustomobject]@{Code='full';Label='Runtime complet isolé (multi Carbon)'})
$Ui.RemoteBindCombo.DisplayMemberPath='Label'
$Ui.RemoteBindCombo.SelectedValuePath='Code'
$Ui.RemoteBindCombo.ItemsSource=@([pscustomobject]@{Code='127.0.0.1';Label='Ce PC uniquement (recommandé)'},[pscustomobject]@{Code='0.0.0.0';Label='Réseau local / VPN (expert)'})
$Ui.CatalogCategoryCombo.ItemsSource=@('Toutes','Administration','Gameplay','Économie','Utilitaire','Autre')
$Ui.CatalogCategoryCombo.SelectedIndex=0
$script:ChoiceLocalizationReady=$true
Set-LocalizedChoiceSources -Code $InitialLanguage

# ----- Editeur du lobby du ciel ----------------------------------------------
# Ecrit server\carbon\data\RustGameHub_Lobby.json, le fichier que RustGameHub
# relit a chaque lobby.rebuild. Meme format des deux cotes : une ligne de
# caracteres par rangee, '.' vide, '#' sol, 'S' apparition, '1'-'9' portail.

$script:LobbyEditorLoaded = $false
$script:LobbyEditorBuilt = $false
$script:LobbyDirty = $false
$script:LobbyCells = $null
$script:LobbyCellViews = $null
$script:LobbyTool = '#'
$script:LobbyToolButtons = @{}
$script:LobbyPortalRows = @{}
$script:LobbyLoading = $false
$script:LobbyModeKeys = @('', 'duel', 'gungame', 'battlefield', 'ctf', 'domination', 'snd', 'extraction', 'zombie', 'towerdefense', 'training')
$script:LobbyModeLabels = @('(aucun)', 'Duel', 'Gun Game', 'Battlefield', 'CTF', 'Domination', 'Search & Destroy', 'Extraction', 'Zombie', 'Tower Defense', 'Entraînement')
$script:LobbyGradeKeys = @('paille', 'bois', 'pierre', 'metal', 'blinde')
$script:LobbyGradeLabels = @('Paille', 'Bois', 'Pierre', 'Métal', 'Blindé')
$script:LobbyRoundGrid = @(
    '....#####....', '...###9###...', '..##1###2##..', '.###########.', '##8#######3##', '#############', '######S######',
    '#############', '##7#######4##', '.###########.', '..##6###5##..', '...#######...', '....#####....'
)
$script:LobbySquareGrid = @(
    '###########', '#1#######2#', '###########', '###########', '#8#######3#', '#####S#####',
    '#7#######4#', '###########', '###########', '#6#######5#', '###########'
)

function Get-LobbyLayoutPath { Join-Path $ServerRoot 'server\carbon\data\RustGameHub_Lobby.json' }

function Test-LobbyPortalChar([char]$Char) { return ([int]$Char -ge [int][char]'1' -and [int]$Char -le [int][char]'9') }
function Test-LobbyFloorChar([char]$Char) { return ($Char -eq [char]'#' -or $Char -eq [char]'S' -or (Test-LobbyPortalChar $Char)) }

function New-DefaultLobbyLayout {
    # Identique au plan par defaut du plugin : sans fichier, l'editeur montre
    # exactement ce que le serveur construit.
    $Portals = @(
        @{ Emplacement = 1; Mode = 'duel'; Nom = 'DUEL' }, @{ Emplacement = 2; Mode = 'gungame'; Nom = 'GUN GAME' },
        @{ Emplacement = 3; Mode = 'ctf'; Nom = 'CTF' }, @{ Emplacement = 4; Mode = 'domination'; Nom = 'DOMINATION' },
        @{ Emplacement = 5; Mode = 'snd'; Nom = 'SEARCH & DESTROY' }, @{ Emplacement = 6; Mode = 'extraction'; Nom = 'EXTRACTION' },
        @{ Emplacement = 7; Mode = 'zombie'; Nom = 'ZOMBIE' }, @{ Emplacement = 8; Mode = 'towerdefense'; Nom = 'TOWER DEFENSE' },
        @{ Emplacement = 9; Mode = 'training'; Nom = 'ENTRAINEMENT' }
    ) | ForEach-Object { [pscustomobject]$_ }
    return [pscustomobject]@{
        Nom = 'Lobby du ciel'; MiniJeux = $true; Altitude = 300; Grade = 'metal'; GardeCorps = $true; JourPermanent = $true
        Grille = $script:LobbyRoundGrid; Portails = $Portals
    }
}

function Initialize-LobbyEditor {
    if ($script:LobbyEditorBuilt) { return }
    $script:LobbyEditorBuilt = $true

    $Tools = @(
        [pscustomobject]@{ Char = '#'; Label = 'SOL' },
        [pscustomobject]@{ Char = 'S'; Label = 'APPARITION' },
        [pscustomobject]@{ Char = '.'; Label = 'GOMME' }
    ) + @(1..9 | ForEach-Object { [pscustomobject]@{ Char = [string]$_; Label = "PORTAIL $_" } })
    foreach ($Tool in $Tools) {
        $Button = New-Object Windows.Controls.Button
        $Button.Style = $Window.FindResource('SmallButton')
        $Button.Margin = '0,0,6,8'
        $Button.Tag = [string]$Tool.Char
        $Button.Content = $Tool.Label
        $Button.Add_Click({ param($Sender) Set-LobbyTool ([string]$Sender.Tag) })
        [void]$Ui.LobbyToolPanel.Children.Add($Button)
        $script:LobbyToolButtons[[string]$Tool.Char] = $Button
    }

    foreach ($Label in $script:LobbyGradeLabels) { [void]$Ui.LobbyGradeCombo.Items.Add($Label) }

    for ($Slot = 1; $Slot -le 9; $Slot++) {
        $Container = New-Object Windows.Controls.StackPanel
        $Container.Margin = '0,0,0,8'
        $Row = New-Object Windows.Controls.Grid
        $Widths = @(
            (New-Object Windows.GridLength 26),
            (New-Object Windows.GridLength 1, ([Windows.GridUnitType]::Star)),
            (New-Object Windows.GridLength 8),
            (New-Object Windows.GridLength 112)
        )
        foreach ($Width in $Widths) {
            $Column = New-Object Windows.Controls.ColumnDefinition
            $Column.Width = $Width
            [void]$Row.ColumnDefinitions.Add($Column)
        }
        $Number = New-Object Windows.Controls.TextBlock
        $Number.Text = [string]$Slot
        $Number.FontWeight = 'Bold'
        $Number.Foreground = $BrushConverter.ConvertFromString('#EFA45D')
        $Number.VerticalAlignment = 'Center'
        $Combo = New-Object Windows.Controls.ComboBox
        foreach ($Label in $script:LobbyModeLabels) { [void]$Combo.Items.Add($Label) }
        $Combo.SelectedIndex = 0
        [Windows.Controls.Grid]::SetColumn($Combo, 1)
        $NameBox = New-Object Windows.Controls.TextBox
        $NameBox.ToolTip = 'Nom affiché au-dessus du portail (facultatif)'
        [Windows.Controls.Grid]::SetColumn($NameBox, 3)
        [void]$Row.Children.Add($Number)
        [void]$Row.Children.Add($Combo)
        [void]$Row.Children.Add($NameBox)
        $Hint = New-Object Windows.Controls.TextBlock
        $Hint.FontSize = 10
        $Hint.Margin = '26,2,0,0'
        $Hint.Foreground = $BrushConverter.ConvertFromString('#E2A33D')
        $Hint.Visibility = 'Collapsed'
        [void]$Container.Children.Add($Row)
        [void]$Container.Children.Add($Hint)
        [void]$Ui.LobbyPortalPanel.Children.Add($Container)
        $Combo.Add_SelectionChanged({ if (-not $script:LobbyLoading) { $script:LobbyDirty = $true; Update-LobbyStats; Request-LobbyPreview } })
        $NameBox.Add_TextChanged({ if (-not $script:LobbyLoading) { $script:LobbyDirty = $true } })
        $script:LobbyPortalRows[$Slot] = [pscustomobject]@{ Combo = $Combo; NameBox = $NameBox; Hint = $Hint }
    }

    foreach ($Control in $Ui.LobbyNameBox, $Ui.LobbyAltitudeBox) { $Control.Add_TextChanged({ if (-not $script:LobbyLoading) { $script:LobbyDirty = $true } }) }
    foreach ($Control in $Ui.LobbyRailCheck, $Ui.LobbyDayCheck, $Ui.LobbyMiniGamesCheck) {
        $Control.Add_Click({ if (-not $script:LobbyLoading) { $script:LobbyDirty = $true; Update-LobbyStats; Request-LobbyPreview } })
    }
    $Ui.LobbyGradeCombo.Add_SelectionChanged({ if (-not $script:LobbyLoading) { $script:LobbyDirty = $true; Request-LobbyPreview } })
    Set-LobbyTool '#'
}

function Set-LobbyTool([string]$Char) {
    $script:LobbyTool = $Char
    foreach ($Key in $script:LobbyToolButtons.Keys) {
        $Button = $script:LobbyToolButtons[$Key]
        $Active = $Key -ceq $Char
        $Button.Background = $BrushConverter.ConvertFromString($(if ($Active) { '#D65332' } else { '#2A2622' }))
        $Button.Foreground = $BrushConverter.ConvertFromString($(if ($Active) { '#FFF6EC' } else { '#C6BDB1' }))
    }
}

function Load-LobbyEditor([switch]$Force) {
    Initialize-LobbyEditor
    if ($script:LobbyEditorLoaded -and -not $Force) { return }

    $Path = Get-LobbyLayoutPath
    $Layout = $null
    $Source = "plan par défaut : le serveur n'a pas encore créé de fichier"
    if (Test-Path -LiteralPath $Path) {
        try {
            $Layout = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
            $Source = $Path
        }
        catch {
            $Layout = $null
            $Source = "le fichier existant est illisible (" + $_.Exception.Message + "). Plan par défaut affiché ; enregistrer remplacera le fichier."
        }
    }
    # Un lobby construit en jeu peut n'avoir aucune grille : ce n'est pas un plan vide.
    $HasObjects = $Layout -and @($Layout.Objets | Where-Object { $_ }).Count -gt 0
    if (-not $Layout -or (@($Layout.Grille).Count -eq 0 -and -not $HasObjects)) { $Layout = New-DefaultLobbyLayout }

    $script:LobbyLoading = $true
    try {
        $Ui.LobbyNameBox.Text = [string]$Layout.Nom
        $Ui.LobbyAltitudeBox.Text = ([double]$Layout.Altitude).ToString([Globalization.CultureInfo]::InvariantCulture)
        $Ui.LobbyRailCheck.IsChecked = [bool]$Layout.GardeCorps
        $Ui.LobbyDayCheck.IsChecked = [bool]$Layout.JourPermanent
        $Ui.LobbyMiniGamesCheck.IsChecked = [bool]$Layout.MiniJeux
        $GradeIndex = [Array]::IndexOf($script:LobbyGradeKeys, ([string]$Layout.Grade).ToLowerInvariant())
        $Ui.LobbyGradeCombo.SelectedIndex = if ($GradeIndex -ge 0) { $GradeIndex } else { 3 }

        $GridRows = @($Layout.Grille)
        if ($GridRows.Count -eq 0) { $GridRows = $script:LobbyRoundGrid }
        Set-LobbyGridFromRows $GridRows
        # Gardes tels quels et reecrits a l'enregistrement : la grille ne doit
        # jamais effacer une construction faite en jeu.
        $script:LobbyObjects = @($Layout.Objets | Where-Object { $_ })
        $script:LobbySpawns3D = @($Layout.Apparitions | Where-Object { $_ })
        $script:LobbyPortals3D = @($Layout.PortailsLibres | Where-Object { $_ })

        foreach ($Slot in $script:LobbyPortalRows.Keys) {
            $Row = $script:LobbyPortalRows[$Slot]
            $Row.Combo.SelectedIndex = 0
            $Row.NameBox.Text = ''
        }
        foreach ($Portal in @($Layout.Portails)) {
            if (-not $Portal) { continue }
            $Slot = [int]$Portal.Emplacement
            if (-not $script:LobbyPortalRows.ContainsKey($Slot)) { continue }
            $Index = [Array]::IndexOf($script:LobbyModeKeys, ([string]$Portal.Mode).ToLowerInvariant())
            $script:LobbyPortalRows[$Slot].Combo.SelectedIndex = if ($Index -ge 0) { $Index } else { 0 }
            $script:LobbyPortalRows[$Slot].NameBox.Text = [string]$Portal.Nom
        }
    }
    finally { $script:LobbyLoading = $false }

    $script:LobbyEditorLoaded = $true
    $script:LobbyDirty = $false
    Update-LobbyStats
    $Ui.LobbyNoticeText.Text = "Plan chargé depuis : $Source"
    Update-LobbyMode3DUi
    Update-LobbyPreview -ResetCamera
}

function Set-LobbyGridFromRows([string[]]$Rows) {
    $Clean = @($Rows | Select-Object -First 40 | ForEach-Object { if ($null -eq $_) { '' } else { [string]$_ } })
    if ($Clean.Count -eq 0) { $Clean = @('.') }
    $Cols = [int][Math]::Min(40, [Math]::Max(1, [int]($Clean | Measure-Object -Property Length -Maximum).Maximum))
    $script:LobbyCells = New-Object 'System.Collections.Generic.List[char[]]'
    foreach ($Line in $Clean) {
        $Cells = New-Object char[] $Cols
        for ($C = 0; $C -lt $Cols; $C++) {
            $Char = if ($C -lt $Line.Length) { $Line[$C] } else { [char]'.' }
            # Un caractere inconnu devient du vide plutot que du sol devine.
            $Cells[$C] = if (Test-LobbyFloorChar $Char) { $Char } else { [char]'.' }
        }
        [void]$script:LobbyCells.Add($Cells)
    }
    $Ui.LobbyRowsBox.Text = [string]$script:LobbyCells.Count
    $Ui.LobbyColsBox.Text = [string]$Cols
    Draw-LobbyGrid
    Request-LobbyPreview
}

function Draw-LobbyGrid {
    $Rows = $script:LobbyCells.Count
    $Cols = $script:LobbyCells[0].Length
    $Grid = $Ui.LobbyGrid
    $Grid.Children.Clear()
    $Grid.Rows = $Rows
    $Grid.Columns = $Cols
    $Size = [Math]::Max(13, [Math]::Min(28, [int](560 / [Math]::Max($Rows, $Cols))))
    $LineBrush = $BrushConverter.ConvertFromString('#2A2622')
    $script:LobbyCellViews = New-Object 'object[,]' $Rows, $Cols
    for ($R = 0; $R -lt $Rows; $R++) {
        for ($C = 0; $C -lt $Cols; $C++) {
            $Border = New-Object Windows.Controls.Border
            $Border.Width = $Size
            $Border.Height = $Size
            $Border.BorderThickness = [Windows.Thickness]::new(0.5)
            $Border.BorderBrush = $LineBrush
            $Label = New-Object Windows.Controls.TextBlock
            $Label.FontSize = [Math]::Max(9, $Size - 12)
            $Label.FontWeight = 'Bold'
            $Label.HorizontalAlignment = 'Center'
            $Label.VerticalAlignment = 'Center'
            $Label.Foreground = $BrushConverter.ConvertFromString('#FFF6EC')
            $Label.IsHitTestVisible = $false
            $Border.Child = $Label
            $Border.Tag = "$R,$C"
            # $Event est une variable automatique de PowerShell : on ne l'emploie
            # pas comme nom de parametre.
            $Border.Add_MouseLeftButtonDown({ param($Sender, $E) Invoke-LobbyPaint ([string]$Sender.Tag) $script:LobbyTool; $E.Handled = $true })
            $Border.Add_MouseRightButtonDown({ param($Sender, $E) Invoke-LobbyPaint ([string]$Sender.Tag) '.'; $E.Handled = $true })
            $Border.Add_MouseEnter({
                param($Sender, $E)
                # Peinture en glissant : on suit le bouton enfonce d'une case a l'autre.
                if ($E.LeftButton -eq [Windows.Input.MouseButtonState]::Pressed) { Invoke-LobbyPaint ([string]$Sender.Tag) $script:LobbyTool }
                elseif ($E.RightButton -eq [Windows.Input.MouseButtonState]::Pressed) { Invoke-LobbyPaint ([string]$Sender.Tag) '.' }
            })
            [void]$Grid.Children.Add($Border)
            $script:LobbyCellViews[$R, $C] = $Border
            Update-LobbyCellView $R $C
        }
    }
}

function Update-LobbyCellView([int]$R, [int]$C) {
    $Char = $script:LobbyCells[$R][$C]
    $Border = $script:LobbyCellViews[$R, $C]
    if (-not $Border) { return }
    $Color = '#15130F'
    $Text = ''
    if ($Char -eq [char]'#') { $Color = '#6F675D' }
    elseif ($Char -eq [char]'S') { $Color = '#2E8B57'; $Text = 'S' }
    elseif (Test-LobbyPortalChar $Char) { $Color = '#D65332'; $Text = [string]$Char }
    $Border.Background = $BrushConverter.ConvertFromString($Color)
    $Border.Child.Text = $Text
}

function Invoke-LobbyPaint([string]$Tag, [string]$Tool) {
    try {
        $Parts = $Tag.Split(',')
        $R = [int]$Parts[0]
        $C = [int]$Parts[1]
        $Char = [char]$Tool
        if ($script:LobbyCells[$R][$C] -eq $Char) { return }
        if (Test-LobbyPortalChar $Char) {
            # Un portail n'existe qu'une fois : le poser ailleurs le deplace.
            for ($RR = 0; $RR -lt $script:LobbyCells.Count; $RR++) {
                for ($CC = 0; $CC -lt $script:LobbyCells[$RR].Length; $CC++) {
                    if ($script:LobbyCells[$RR][$CC] -eq $Char) {
                        $script:LobbyCells[$RR][$CC] = [char]'#'
                        Update-LobbyCellView $RR $CC
                    }
                }
            }
        }
        $script:LobbyCells[$R][$C] = $Char
        Update-LobbyCellView $R $C
        $script:LobbyDirty = $true
        Update-LobbyStats
        Request-LobbyPreview
    }
    catch { Set-Activity ('Editeur de lobby : ' + $_.Exception.Message) }
}

function Get-LobbyRows {
    return @($script:LobbyCells | ForEach-Object { -join $_ })
}

function Update-LobbyStats {
    if (-not $script:LobbyCells) { return }
    $Rows = $script:LobbyCells.Count
    $Cols = $script:LobbyCells[0].Length
    $Floors = 0; $Spawns = 0; $Rails = 0
    $Placed = @{}
    for ($R = 0; $R -lt $Rows; $R++) {
        for ($C = 0; $C -lt $Cols; $C++) {
            $Char = $script:LobbyCells[$R][$C]
            if (-not (Test-LobbyFloorChar $Char)) { continue }
            $Floors++
            if ($Char -eq [char]'S') { $Spawns++ }
            if (Test-LobbyPortalChar $Char) { $Placed[[int][string]$Char] = $true }
            foreach ($Step in @(@(-1, 0), @(1, 0), @(0, 1), @(0, -1))) {
                $NR = $R + $Step[0]; $NC = $C + $Step[1]
                $Neighbour = $NR -ge 0 -and $NR -lt $Rows -and $NC -ge 0 -and $NC -lt $Cols -and (Test-LobbyFloorChar $script:LobbyCells[$NR][$NC])
                if (-not $Neighbour) { $Rails++ }
            }
        }
    }
    if (-not [bool]$Ui.LobbyRailCheck.IsChecked) { $Rails = 0 }

    $Warnings = New-Object System.Collections.Generic.List[string]
    $ActivePortals = 0
    foreach ($Slot in 1..9) {
        $Row = $script:LobbyPortalRows[$Slot]
        if (-not $Row) { continue }
        $HasMode = $Row.Combo.SelectedIndex -gt 0
        $OnGrid = $Placed.ContainsKey($Slot)
        if ($HasMode -and $OnGrid) { $ActivePortals++ }
        $Row.Hint.Visibility = 'Collapsed'
        if ($HasMode -and -not $OnGrid) { $Row.Hint.Text = "Pas encore posé sur la grille : outil PORTAIL $Slot."; $Row.Hint.Visibility = 'Visible' }
        elseif ($OnGrid -and -not $HasMode) { $Row.Hint.Text = 'Posé sur la grille, mais aucun mode choisi : ce portail restera inactif.'; $Row.Hint.Visibility = 'Visible' }
    }
    $Entities = $Floors + $Rails + 2 * $ActivePortals
    $Ui.LobbyStatsText.Text = "$Rows × $Cols cases ($($Cols * 3) m × $($Rows * 3) m) · $Floors fondations · $Rails garde-corps · $Spawns apparition(s) · $ActivePortals portail(s) actif(s) · ≈ $Entities entités"

    if ($Floors -eq 0) { $Warnings.Add('Plan vide : il faut au moins une case de sol.') }
    if ($Floors -gt 0 -and $Spawns -eq 0) { $Warnings.Add("Aucune case d'apparition : les joueurs arriveront au centre du plan.") }
    if ($Entities -gt 700) { $Warnings.Add("Plan lourd ($Entities entités) : prévois un léger temps de construction et plus de trafic réseau.") }
    $Ui.LobbyWarningText.Text = ($Warnings -join "`n")
}

function Resize-LobbyGrid {
    $Rows = 0; $Cols = 0
    if (-not [int]::TryParse($Ui.LobbyRowsBox.Text, [ref]$Rows) -or -not [int]::TryParse($Ui.LobbyColsBox.Text, [ref]$Cols)) { throw 'Lignes et colonnes doivent être des nombres entiers.' }
    if ($Rows -lt 3 -or $Rows -gt 40 -or $Cols -lt 3 -or $Cols -gt 40) { throw 'La grille va de 3 à 40 cases de côté.' }
    $Old = $script:LobbyCells
    $Lines = for ($R = 0; $R -lt $Rows; $R++) {
        $Line = ''
        for ($C = 0; $C -lt $Cols; $C++) {
            $Piece = '.'
            if ($R -lt $Old.Count -and $C -lt $Old[$R].Length) { $Piece = [string]$Old[$R][$C] }
            $Line += $Piece
        }
        $Line
    }
    Set-LobbyGridFromRows @($Lines)
    $script:LobbyDirty = $true
    Update-LobbyStats
}

function Set-LobbyPreset([string[]]$Rows) {
    Set-LobbyGridFromRows $Rows
    $script:LobbyDirty = $true
    Update-LobbyStats
}

function Clear-LobbyGrid {
    if (-not (Confirm-Action 'Effacer toute la grille ? Les réglages et les modes des portails sont conservés.' 'Tout effacer')) { return }
    $Rows = $script:LobbyCells.Count
    $Cols = $script:LobbyCells[0].Length
    Set-LobbyPreset @(1..$Rows | ForEach-Object { '.' * $Cols })
}

function Save-LobbyEditor {
    if (-not $script:LobbyCells) { throw "Aucun plan chargé." }
    $Rows = Get-LobbyRows
    $Floors = (($Rows -join '').ToCharArray() | Where-Object { Test-LobbyFloorChar $_ }).Count
    if ($Floors -eq 0) { throw 'Plan vide : dessine au moins une case de sol avant d''enregistrer.' }

    $Altitude = 0.0
    $AltitudeText = ([string]$Ui.LobbyAltitudeBox.Text).Trim().Replace(',', '.')
    if (-not [double]::TryParse($AltitudeText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$Altitude)) { throw "L'altitude doit être un nombre, par exemple 300." }
    if ($Altitude -lt 100 -or $Altitude -gt 1000) { throw "Altitude entre 100 et 1000 m : plus bas, le lobby risque de toucher le relief." }
    $Name = ([string]$Ui.LobbyNameBox.Text).Trim()
    if (-not $Name) { $Name = 'Lobby du ciel' }
    $GradeIndex = [Math]::Max(0, $Ui.LobbyGradeCombo.SelectedIndex)

    $Portals = New-Object System.Collections.Generic.List[object]
    foreach ($Slot in 1..9) {
        $Row = $script:LobbyPortalRows[$Slot]
        if (-not $Row -or $Row.Combo.SelectedIndex -le 0) { continue }
        $Portals.Add([ordered]@{ Emplacement = $Slot; Mode = $script:LobbyModeKeys[$Row.Combo.SelectedIndex]; Nom = ([string]$Row.NameBox.Text).Trim() })
    }

    $Layout = [ordered]@{
        Nom = $Name
        MiniJeux = [bool]$Ui.LobbyMiniGamesCheck.IsChecked
        Altitude = $Altitude
        Grade = $script:LobbyGradeKeys[$GradeIndex]
        GardeCorps = [bool]$Ui.LobbyRailCheck.IsChecked
        JourPermanent = [bool]$Ui.LobbyDayCheck.IsChecked
        Grille = [object[]]$Rows
        Portails = [object[]]$Portals.ToArray()
        Objets = [object[]]@($script:LobbyObjects)
        Apparitions = [object[]]@($script:LobbySpawns3D)
        PortailsLibres = [object[]]@($script:LobbyPortals3D)
    }
    $Json = $Layout | ConvertTo-Json -Depth 6

    # Ecriture atomique : un fichier a moitie ecrit casserait la construction.
    $Path = Get-LobbyLayoutPath
    $Directory = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Force -Path $Directory | Out-Null }
    $Temp = $Path + '.tmp'
    [IO.File]::WriteAllText($Temp, $Json, (New-Object Text.UTF8Encoding($false)))
    $null = Get-Content -LiteralPath $Temp -Raw -Encoding utf8 | ConvertFrom-Json
    Move-Item -LiteralPath $Temp -Destination $Path -Force

    $script:LobbyDirty = $false
    Set-Activity "Plan du lobby enregistré ($Floors fondations)."
    $Ui.LobbyNoticeText.Text = "Plan enregistré dans $Path."
}

function Apply-LobbyEditor {
    Save-LobbyEditor
    if (-not (Get-RustRpgServerState).Running) {
        $Ui.LobbyNoticeText.Text = "Plan enregistré. Le serveur est arrêté : le lobby sera construit à son prochain démarrage."
        return
    }
    $Ui.LobbyNoticeText.Text = 'Plan enregistré. Construction en cours sur le serveur...'
    Queue-ServerOperation -Operation command -Command 'lobby.rebuild' -Label 'construction du lobby' -TimeoutMs 30000 -OnSuccess {
        param($Response)
        Complete-LobbyApply $Response
    }
}

function Complete-LobbyApply([string]$Response) {
    $Text = ([string]$Response).Trim()
    # Rust renvoie la sortie journal emise pendant la commande avec le meme
    # identifiant : la reponse est la ligne « Lobby ... construit a ... m ».
    if ($Text -match 'Lobby reconstruit|construit a \d+ m') {
        $Ui.LobbyNoticeText.Text = "Lobby construit sur le serveur. $Text"
        Set-Activity 'Lobby reconstruit.'
    }
    else {
        $Ui.LobbyNoticeText.Text = "Réponse inattendue du serveur : « $Text ». Vérifie que l'extension RustGameHub est active."
    }
}

function Reload-LobbyEditor {
    if ($script:LobbyDirty -and -not (Confirm-Action 'Abandonner les modifications non enregistrées et recharger le plan du serveur ?' 'Recharger le plan')) { return }
    Load-LobbyEditor -Force
}

# ----- Lobby construit en jeu + apercu 3D -------------------------------------
# Les champs 3D (Objets, Apparitions, PortailsLibres) sont relus et reecrits tels
# quels : enregistrer depuis la grille ne doit jamais effacer une construction
# faite en jeu avec /lobby save.

$script:LobbyObjects = @()
$script:LobbySpawns3D = @()
$script:LobbyPortals3D = @()
$script:LobbyCamYaw = 225.0
$script:LobbyCamPitch = 35.0
$script:LobbyCamDistance = 60.0
$script:LobbyCamTarget = New-Object Windows.Media.Media3D.Point3D 0, 0, 0
$script:LobbyDragStart = $null
$script:LobbyPreviewTimer = New-Object Windows.Threading.DispatcherTimer
$script:LobbyPreviewTimer.Interval = [TimeSpan]::FromMilliseconds(450)
$script:LobbyPreviewTimer.Add_Tick({ $script:LobbyPreviewTimer.Stop(); Update-LobbyPreview })
$script:LobbyGradeColors = @('#C9B27C', '#9A6A3A', '#9C978F', '#7C8893', '#55606C')

function Test-LobbyHas3D { return @($script:LobbyObjects).Count -gt 0 }

function Update-LobbyMode3DUi {
    $Has3D = Test-LobbyHas3D
    $Ui.LobbyGridModeButton.Visibility = if ($Has3D) { 'Visible' } else { 'Collapsed' }
    if ($Has3D) {
        $Ui.LobbyNoticeText.Text = "Ce lobby a été construit en jeu ($(@($script:LobbyObjects).Count) objets). Tant qu'il est en mode 3D, la grille ne s'applique pas ; nom, altitude et options restent modifiables. Pour modifier la construction : /lobby edit en jeu. Pour revenir au plan en grille : REVENIR À LA GRILLE."
    }
}

function Request-LobbyPreview {
    # Regroupe les mises a jour : peindre en glissant ne reconstruit l'apercu
    # qu'une fois la souris posee.
    $script:LobbyPreviewTimer.Stop()
    $script:LobbyPreviewTimer.Start()
}

function Get-LobbyShapeSize([string]$Prefab) {
    # Formes simplifiees : largeur (x local), hauteur, profondeur (z local) et
    # bas de la forme par rapport au pivot. Un mur s'etend sur son z local.
    $Name = ([string]$Prefab).ToLowerInvariant()
    $Name = $Name.Substring($Name.LastIndexOf('/') + 1).Replace('.prefab', '')
    if ($Name -like 'foundation.triangle*') { return @(2.6, 1.0, 2.6, -1.0, $true) }
    if ($Name -like 'foundation*') { return @(3.0, 1.0, 3.0, -1.0, $true) }
    if ($Name -like 'floor*') { return @(3.0, 0.15, 3.0, -0.15, $true) }
    # Un mur-cadre est une arcade ouverte : on n'en dessine que le linteau,
    # sinon le kiosque central ressemble a un bloc plein.
    if ($Name -like 'wall.frame*') { return @(0.25, 0.5, 3.0, 2.5, $true) }
    if ($Name -like 'wall.low*') { return @(0.2, 1.0, 3.0, 0.0, $true) }
    if ($Name -like 'wall.half*') { return @(0.2, 1.5, 3.0, 0.0, $true) }
    if ($Name -like 'wall*') { return @(0.2, 3.0, 3.0, 0.0, $true) }
    if ($Name -like 'roof*') { return @(3.0, 1.5, 3.0, 0.0, $true) }
    if ($Name -like '*stair*') { return @(3.0, 3.0, 3.0, 0.0, $true) }
    if ($Name -like 'ramp*') { return @(3.0, 0.6, 3.0, 0.0, $true) }
    return @(0.8, 0.8, 0.8, 0.0, $false)
}

function Get-LobbyPreviewBoxes {
    $Boxes = New-Object System.Collections.Generic.List[object]
    if (Test-LobbyHas3D) {
        foreach ($Item in $script:LobbyObjects) {
            $Size = Get-LobbyShapeSize ([string]$Item.Prefab)
            $Grade = [int]$Item.Grade
            $Color = if ($Size[4] -and $Grade -ge 0 -and $Grade -lt 5) { $script:LobbyGradeColors[$Grade] } elseif ($Size[4]) { '#7C8893' } else { '#D9A441' }
            $Boxes.Add(@([double]$Item.X, [double]$Item.Y, [double]$Item.Z, [double]$Item.RY, $Size[0], $Size[1], $Size[2], $Size[3], $Color))
        }
        foreach ($Point in $script:LobbySpawns3D) { $Boxes.Add(@([double]$Point.X, [double]$Point.Y, [double]$Point.Z, 0.0, 0.8, 1.8, 0.8, 0.0, '#3DBB6E')) }
        foreach ($Portal in $script:LobbyPortals3D) { $Boxes.Add(@([double]$Portal.X, [double]$Portal.Y, [double]$Portal.Z, 0.0, 1.0, 2.2, 1.0, 0.0, '#E5582F')) }
        # La virgule empeche PowerShell de derouler la liste au retour : avec un
        # seul bloc, l'appelant recevrait sinon ses neuf nombres un par un.
        return ,$Boxes
    }

    if (-not $script:LobbyCells) { return ,$Boxes }
    $Rows = $script:LobbyCells.Count
    $Cols = $script:LobbyCells[0].Length
    $GradeIndex = [Math]::Max(0, [Math]::Min(4, $Ui.LobbyGradeCombo.SelectedIndex))
    $FloorColor = $script:LobbyGradeColors[$GradeIndex]
    $Rails = [bool]$Ui.LobbyRailCheck.IsChecked
    for ($R = 0; $R -lt $Rows; $R++) {
        for ($C = 0; $C -lt $Cols; $C++) {
            $Char = $script:LobbyCells[$R][$C]
            if (-not (Test-LobbyFloorChar $Char)) { continue }
            # Meme repere que le plugin : ligne 0 au nord (+z).
            $X = ($C - ($Cols - 1) / 2.0) * 3.0
            $Z = (($Rows - 1) / 2.0 - $R) * 3.0
            $Boxes.Add(@($X, 0.0, $Z, 0.0, 3.0, 1.0, 3.0, -1.0, $FloorColor))
            if ($Char -eq [char]'S') { $Boxes.Add(@($X, 0.0, $Z, 0.0, 0.8, 1.8, 0.8, 0.0, '#3DBB6E')) }
            elseif (Test-LobbyPortalChar $Char) {
                $Slot = [int][string]$Char
                $Row = $script:LobbyPortalRows[$Slot]
                $Color = if ($Row -and $Row.Combo.SelectedIndex -gt 0) { '#E5582F' } else { '#7A6F64' }
                $Boxes.Add(@($X, 0.0, $Z, 0.0, 1.0, 2.2, 1.0, 0.0, $Color))
            }
            if (-not $Rails) { continue }
            foreach ($Edge in @(@(-1, 0, 0.0, 1.5, 90.0), @(1, 0, 0.0, -1.5, 90.0), @(0, 1, 1.5, 0.0, 0.0), @(0, -1, -1.5, 0.0, 0.0))) {
                $NR = $R + $Edge[0]; $NC = $C + $Edge[1]
                $Open = -not ($NR -ge 0 -and $NR -lt $Rows -and $NC -ge 0 -and $NC -lt $Cols -and (Test-LobbyFloorChar $script:LobbyCells[$NR][$NC]))
                if ($Open) { $Boxes.Add(@(($X + $Edge[2]), 0.0, ($Z + $Edge[3]), $Edge[4], 0.2, 1.0, 3.0, 0.0, $FloorColor)) }
            }
        }
    }
    return ,$Boxes
}

function Update-LobbyPreview([switch]$ResetCamera) {
    try {
        $Boxes = Get-LobbyPreviewBoxes
        $Meshes = @{}
        # Six faces, quatre sommets chacune : des normales franches par face,
        # sinon WPF lisse les aretes et les blocs deviennent des galets.
        $Faces = @(
            @(@(0,0,1), @(1,0,1), @(1,1,1), @(0,1,1)), @(@(1,0,0), @(0,0,0), @(0,1,0), @(1,1,0)),
            @(@(0,1,1), @(1,1,1), @(1,1,0), @(0,1,0)), @(@(0,0,0), @(1,0,0), @(1,0,1), @(0,0,1)),
            @(@(1,0,1), @(1,0,0), @(1,1,0), @(1,1,1)), @(@(0,0,0), @(0,0,1), @(0,1,1), @(0,1,0))
        )
        $MinX = [double]::MaxValue; $MaxX = [double]::MinValue; $MinY = [double]::MaxValue; $MaxY = [double]::MinValue; $MinZ = [double]::MaxValue; $MaxZ = [double]::MinValue
        foreach ($Box in $Boxes) {
            $Color = [string]$Box[8]
            if (-not $Meshes.ContainsKey($Color)) {
                $Meshes[$Color] = [pscustomobject]@{ Points = New-Object Windows.Media.Media3D.Point3DCollection; Indices = New-Object Windows.Media.Int32Collection }
            }
            $Mesh = $Meshes[$Color]
            $Angle = [double]$Box[3] * [Math]::PI / 180.0
            $Cos = [Math]::Cos($Angle); $Sin = [Math]::Sin($Angle)
            $W = [double]$Box[4]; $H = [double]$Box[5]; $D = [double]$Box[6]; $Bottom = [double]$Box[7]
            foreach ($Face in $Faces) {
                $Start = $Mesh.Points.Count
                foreach ($Corner in $Face) {
                    $LX = ($Corner[0] - 0.5) * $W
                    $LY = $Bottom + $Corner[1] * $H
                    $LZ = ($Corner[2] - 0.5) * $D
                    # Rotation autour de Y a la maniere d'Unity, puis passage au
                    # repere de WPF (z inverse) pour ne pas voir le lobby en miroir.
                    $UX = [double]$Box[0] + $LX * $Cos + $LZ * $Sin
                    $UZ = [double]$Box[2] - $LX * $Sin + $LZ * $Cos
                    $UY = [double]$Box[1] + $LY
                    $Mesh.Points.Add((New-Object Windows.Media.Media3D.Point3D $UX, $UY, (-$UZ)))
                    if ($UX -lt $MinX) { $MinX = $UX }; if ($UX -gt $MaxX) { $MaxX = $UX }
                    if ($UY -lt $MinY) { $MinY = $UY }; if ($UY -gt $MaxY) { $MaxY = $UY }
                    if (-$UZ -lt $MinZ) { $MinZ = -$UZ }; if (-$UZ -gt $MaxZ) { $MaxZ = -$UZ }
                }
                foreach ($Index in 0, 1, 2, 0, 2, 3) { $Mesh.Indices.Add($Start + $Index) }
            }
        }

        $Group = New-Object Windows.Media.Media3D.Model3DGroup
        foreach ($Color in $Meshes.Keys) {
            $Geometry = New-Object Windows.Media.Media3D.MeshGeometry3D
            $Geometry.Positions = $Meshes[$Color].Points
            $Geometry.TriangleIndices = $Meshes[$Color].Indices
            $Material = New-Object Windows.Media.Media3D.DiffuseMaterial ($BrushConverter.ConvertFromString($Color))
            $Model = New-Object Windows.Media.Media3D.GeometryModel3D $Geometry, $Material
            $Model.BackMaterial = $Material
            $Group.Children.Add($Model)
        }
        $Ui.LobbyModelVisual.Content = $Group

        if ($Boxes.Count -gt 0 -and ($ResetCamera -or $script:LobbyCamDistance -le 0)) {
            $script:LobbyCamTarget = New-Object Windows.Media.Media3D.Point3D (($MinX + $MaxX) / 2), (($MinY + $MaxY) / 2), (($MinZ + $MaxZ) / 2)
            $Extent = [Math]::Max([Math]::Max($MaxX - $MinX, $MaxZ - $MinZ), $MaxY - $MinY)
            $script:LobbyCamDistance = [Math]::Max(15.0, $Extent * 1.5 + 10.0)
            $script:LobbyCamYaw = 225.0
            $script:LobbyCamPitch = 35.0
        }
        Update-LobbyCamera
        $Kind = if (Test-LobbyHas3D) { "Construit en jeu : $(@($script:LobbyObjects).Count) objets (formes simplifiées)" } else { "Plan en grille : aperçu de la grille en cours d'édition" }
        $Ui.LobbyPreviewInfoText.Text = "$Kind. Glisse pour tourner, molette pour zoomer."
    }
    catch { $Ui.LobbyPreviewInfoText.Text = 'Aperçu indisponible : ' + $_.Exception.Message }
}

function Update-LobbyCamera {
    $Yaw = $script:LobbyCamYaw * [Math]::PI / 180.0
    $Pitch = $script:LobbyCamPitch * [Math]::PI / 180.0
    $Target = $script:LobbyCamTarget
    $Distance = $script:LobbyCamDistance
    $X = $Target.X + $Distance * [Math]::Cos($Pitch) * [Math]::Cos($Yaw)
    $Y = $Target.Y + $Distance * [Math]::Sin($Pitch)
    $Z = $Target.Z + $Distance * [Math]::Cos($Pitch) * [Math]::Sin($Yaw)
    $Ui.LobbyCamera.Position = New-Object Windows.Media.Media3D.Point3D $X, $Y, $Z
    $Ui.LobbyCamera.LookDirection = New-Object Windows.Media.Media3D.Vector3D ($Target.X - $X), ($Target.Y - $Y), ($Target.Z - $Z)
}

function Switch-LobbyToGrid {
    if (-not (Test-LobbyHas3D)) { return }
    if (-not (Confirm-Action "Revenir au plan en grille ? La construction faite en jeu ne sera plus utilisée. Le serveur en garde une copie : /lobby restore la retrouve." 'Revenir à la grille')) { return }
    $script:LobbyObjects = @()
    $script:LobbySpawns3D = @()
    $script:LobbyPortals3D = @()
    $script:LobbyDirty = $true
    Update-LobbyMode3DUi
    Update-LobbyPreview -ResetCamera
    Apply-LobbyEditor
}

$Ui.LobbyGridModeButton.Add_Click({ Invoke-UiAction { Switch-LobbyToGrid } })
$Ui.LobbyPreviewResetButton.Add_Click({ Invoke-UiAction { Update-LobbyPreview -ResetCamera } })
$Ui.LobbyViewportHost.Add_MouseLeftButtonDown({
    param($Sender, $E)
    $script:LobbyDragStart = $E.GetPosition($Sender)
    [void]$Sender.CaptureMouse()
})
$Ui.LobbyViewportHost.Add_MouseLeftButtonUp({
    param($Sender, $E)
    $script:LobbyDragStart = $null
    $Sender.ReleaseMouseCapture()
})
$Ui.LobbyViewportHost.Add_MouseMove({
    param($Sender, $E)
    if ($null -eq $script:LobbyDragStart) { return }
    $Position = $E.GetPosition($Sender)
    $script:LobbyCamYaw += ($Position.X - $script:LobbyDragStart.X) * 0.4
    $script:LobbyCamPitch = [Math]::Max(5.0, [Math]::Min(85.0, $script:LobbyCamPitch + ($Position.Y - $script:LobbyDragStart.Y) * 0.3))
    $script:LobbyDragStart = $Position
    Update-LobbyCamera
})
$Ui.LobbyViewportHost.Add_MouseWheel({
    param($Sender, $E)
    $Factor = if ($E.Delta -gt 0) { 0.88 } else { 1.14 }
    $script:LobbyCamDistance = [Math]::Max(6.0, [Math]::Min(800.0, $script:LobbyCamDistance * $Factor))
    Update-LobbyCamera
    $E.Handled = $true
})

$Ui.LobbyReloadButton.Add_Click({ Invoke-UiAction { Reload-LobbyEditor } })
$Ui.LobbySaveButton.Add_Click({ Invoke-UiAction { Save-LobbyEditor } })
$Ui.LobbyApplyButton.Add_Click({ Invoke-UiAction { Apply-LobbyEditor } })
$Ui.LobbyResizeButton.Add_Click({ Invoke-UiAction { Resize-LobbyGrid } })
$Ui.LobbyPresetRoundButton.Add_Click({ Invoke-UiAction { Set-LobbyPreset $script:LobbyRoundGrid } })
$Ui.LobbyPresetSquareButton.Add_Click({ Invoke-UiAction { Set-LobbyPreset $script:LobbySquareGrid } })
$Ui.LobbyClearButton.Add_Click({ Invoke-UiAction { Clear-LobbyGrid } })

$Ui.Navigation.Add_SelectionChanged({
    if ($script:WizardNavigationGuard -or $script:NavGuard) { return }
    $Item = $Ui.Navigation.SelectedItem
    if (-not $Item -or $null -eq $Item.Tag) { return }
    $Target = [int]$Item.Tag
    # On rouvre le dernier sous-onglet consulte : revenir a MONDE apres avoir
    # regle les taux ne doit pas renvoyer aux cartes.
    $Section = Get-NavSection $Target
    if ($Section -and $script:SectionLastTab.ContainsKey($Section.Key)) {
        $Last = [int]$script:SectionLastTab[$Section.Key]
        if (-not $script:SubTabHidden.Contains($Last)) { $Target = $Last }
    }
    Invoke-UiAction { Show-AdvancedTab $Target }
})
$Ui.MainTabs.Add_SelectionChanged({
    param($Sender, $Change)
    # Les TabControl imbriques (configuration) font remonter leur propre
    # evenement : on ne reagit qu'a un changement de page principale. Toute
    # affectation directe de MainTabs.SelectedIndex ailleurs dans le code met
    # ainsi la barre et la surbrillance a jour sans rien modifier d'autre.
    if (-not [object]::ReferenceEquals($Change.OriginalSource, $Ui.MainTabs)) { return }
    Update-SubNav
})
$Ui.SimpleNavigation.Add_SelectionChanged({
    if ($script:WizardNavigationGuard) { return }
    if ($script:InterfaceMode -ne 'simple' -or -not $Ui.SimpleNavigation.SelectedItem) { return }
    $TargetTab = [int]$Ui.SimpleNavigation.SelectedItem.Tag
    $Ui.MainTabs.SelectedIndex = $TargetTab
    if ($TargetTab -eq 9 -and -not $script:NetworkDiagnosticRequested) {
        $script:NetworkDiagnosticRequested = $true
        Invoke-UiAction { Refresh-NetworkDiagnostics }
    }
    if ($TargetTab -eq 11) { Invoke-UiAction { Refresh-SimpleMods } }
    if ($TargetTab -eq 12) { Invoke-UiAction { Refresh-SimpleFriends } }
    if ($TargetTab -eq 13) { Invoke-UiAction { Refresh-SimpleServers } }
    if ($TargetTab -eq 14) { Invoke-UiAction { Refresh-OperationCenter } }
    if ($TargetTab -eq 17) { Invoke-UiAction { Refresh-GlobalDiagnostics } }
})
$Ui.InterfaceModeButton.Add_Click({
    Invoke-UiAction {
        $NextMode = if ($script:InterfaceMode -eq 'simple') { 'advanced' } else { 'simple' }
        Apply-InterfaceMode -Mode $NextMode
        Set-Activity $(if ($NextMode -eq 'simple') { 'Mode simple : les cinq parcours essentiels sont affichés.' } else { 'Mode avancé : tous les outils techniques sont disponibles.' })
    }
})
# Les boutons de la liste sont crees par le DataTemplate : on ne peut pas les
# cabler un par un. On ecoute donc le Click qui remonte jusqu'a l'ItemsControl
# et on lit le FileBase depuis le Tag du bouton d'origine.
$Ui.SimpleModsList.AddHandler(
    [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [Windows.RoutedEventHandler]{
        param($Sender, $EventArgs)
        $Button = $EventArgs.OriginalSource -as [Windows.Controls.Button]
        if (-not $Button -or -not $Button.Tag) { return }
        Invoke-UiAction { Invoke-SimpleModToggle ([string]$Button.Tag) }
    })
$Ui.SimpleFriendsSteps.AddHandler(
    [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [Windows.RoutedEventHandler]{
        param($Sender, $EventArgs)
        $Button = $EventArgs.OriginalSource -as [Windows.Controls.Button]
        if (-not $Button -or -not $Button.Tag) { return }
        Invoke-UiAction { Invoke-SimpleFriendsStep ([string]$Button.Tag); Refresh-SimpleFriends }
    })
$Ui.SimpleServersList.AddHandler(
    [Windows.Controls.Primitives.ButtonBase]::ClickEvent,
    [Windows.RoutedEventHandler]{
        param($Sender, $EventArgs)
        $Button = $EventArgs.OriginalSource -as [Windows.Controls.Button]
        if (-not $Button -or -not $Button.Tag) { return }
        Invoke-UiAction { Invoke-SimpleServerAction ([string]$Button.Tag) }
    })
$Ui.SimpleServersRefreshButton.Add_Click({ Invoke-UiAction { Refresh-SimpleServers; Set-Activity 'Liste des serveurs actualisée.' } })
$Ui.SimpleServersInstallButton.Add_Click({ Invoke-UiAction { Start-ServerUpdate } })
$Ui.SimpleServersCreateButton.Add_Click({ Invoke-UiAction { Open-ServerWizard } })
$Ui.SimpleServersAdvancedButton.Add_Click({ Invoke-UiAction { Apply-InterfaceMode -Mode 'advanced'; Select-AdvancedNav -Tab 1; $Ui.MainTabs.SelectedIndex = 1 } })
$Ui.SimpleFriendsCopyButton.Add_Click({ Invoke-UiAction { Invoke-SimpleFriendsStep 'copy' } })
$Ui.SimpleFriendsRefreshButton.Add_Click({ Invoke-UiAction { Refresh-SimpleFriends; Set-Activity 'Vérification réseau terminée.' } })
$Ui.SimpleFriendsAdvancedButton.Add_Click({ Invoke-UiAction { Apply-InterfaceMode -Mode 'advanced'; Select-AdvancedNav -Tab 9; $Ui.MainTabs.SelectedIndex = 9; Refresh-NetworkDiagnostics } })
$Ui.FriendTestStartButton.Add_Click({ Invoke-UiAction { Start-FriendTest } })
$Ui.FriendTestCancelButton.Add_Click({ Invoke-UiAction { Request-FriendTestCancellation } })
$Ui.FriendTestOpenReportButton.Add_Click({ Invoke-UiAction { Open-FriendTestReport } })
$Ui.DashRestartButton.Add_Click({ Invoke-UiAction { Restart-RustServerFromDashboard } })
$Ui.DashConsoleSendButton.Add_Click({ Invoke-UiAction { Invoke-DashConsoleCommand $Ui.DashConsoleBox.Text.Trim() } })
$Ui.DashConsoleBox.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { Invoke-UiAction { Invoke-DashConsoleCommand $Ui.DashConsoleBox.Text.Trim() } } })
$Ui.DashConsoleClearButton.Add_Click({ $Ui.DashConsoleOutput.Text = '' })
$Ui.DashConsoleStatusButton.Add_Click({ Invoke-UiAction { Invoke-DashConsoleCommand 'status' } })
$Ui.DashConsoleSaveButton.Add_Click({ Invoke-UiAction { Invoke-DashConsoleCommand 'server.save' } })
$Ui.DashConsolePluginsButton.Add_Click({ Invoke-UiAction { Invoke-DashConsoleCommand 'c.plugins' } })
$Ui.DashPlayersManageButton.Add_Click({ Invoke-UiAction { Select-AdvancedNav -Tab 7 } })
$Ui.RatesGlobal1Button.Add_Click({ Invoke-UiAction { Apply-RateGlobal '1' } })
$Ui.RatesGlobal2Button.Add_Click({ Invoke-UiAction { Apply-RateGlobal '2' } })
$Ui.RatesGlobal5Button.Add_Click({ Invoke-UiAction { Apply-RateGlobal '5' } })
$Ui.RatesGlobal10Button.Add_Click({ Invoke-UiAction { Apply-RateGlobal '10' } })
$Ui.RatesGlobalApplyButton.Add_Click({ Invoke-UiAction { Apply-RateGlobal $Ui.RatesGlobalBox.Text } })
$Ui.RatesDomainsApplyButton.Add_Click({ Invoke-UiAction { Apply-RateDomains } })
$Ui.RatesResourcesApplyButton.Add_Click({ Invoke-UiAction { Apply-RateResources } })
$Ui.RatesResourcesResetButton.Add_Click({ Invoke-UiAction { Reset-RateResources } })
$Ui.RatesRefreshButton.Add_Click({ Invoke-UiAction { Refresh-Rates; Set-Activity 'Taux actualises.' } })
$Ui.SimpleModsRefreshButton.Add_Click({ Invoke-UiAction { Refresh-SimpleMods; Set-Activity 'Catalogue de plugins actualisé.' } })
$Ui.SimpleModsAdvancedButton.Add_Click({ Invoke-UiAction { Apply-InterfaceMode -Mode 'advanced'; Select-AdvancedNav -Tab 4; $Ui.MainTabs.SelectedIndex = 4 } })
$Ui.SimpleModsEnvActionButton.Add_Click({ Invoke-UiAction { Apply-InterfaceMode -Mode 'advanced'; Select-AdvancedNav -Tab 4; $Ui.MainTabs.SelectedIndex = 4; Set-Activity "Installation de Carbon : utilise le bouton dédié de la page Extensions." } })
$Ui.SimpleModsImportButton.Add_Click({ Invoke-UiAction { Import-PluginFile; Refresh-SimpleMods } })
$Ui.SimpleModsSearchBox.Add_TextChanged({ Invoke-UiAction { Update-SimplePluginCatalogView } })
$Ui.SimpleModsCategoryCombo.Add_SelectionChanged({ Invoke-UiAction { Update-SimplePluginCatalogView } })
$Ui.SimpleModsStateCombo.Add_SelectionChanged({ Invoke-UiAction { Update-SimplePluginCatalogView } })
$Ui.ApplyInstanceIsolationButton.Add_Click({Invoke-UiAction{Apply-SelectedInstanceIsolation}})
$Ui.InstallIsolatedRuntimeButton.Add_Click({Invoke-UiAction{Start-SelectedIsolatedRuntimeInstall}})
$Ui.OpenInstanceRuntimeButton.Add_Click({Invoke-UiAction{Open-SelectedInstanceRuntime}})
$Ui.SupervisionInstanceCombo.Add_SelectionChanged({if(-not$script:InstanceRefreshGuard){Invoke-UiAction{Refresh-Supervision}}})
$Ui.SupervisionRefreshButton.Add_Click({Invoke-UiAction{Refresh-Supervision -IncludeRcon}})
$Ui.SupervisionSavePolicyButton.Add_Click({Invoke-UiAction{Save-SupervisionPolicy}})
$Ui.SupervisionInstallTaskButton.Add_Click({Invoke-UiAction{$null=Register-RustWatchdogTask -ServerRoot $ServerRoot;Refresh-Supervision;Set-Activity 'Supervision en arrière-plan activée.'}})
$Ui.SupervisionRemoveTaskButton.Add_Click({Invoke-UiAction{$null=Unregister-RustWatchdogTask -ServerRoot $ServerRoot;Refresh-Supervision;Set-Activity 'Supervision en arrière-plan désactivée.'}})
$Ui.RemoteSaveButton.Add_Click({Invoke-UiAction{Save-RemoteAccess}})
$Ui.RemoteGenerateTokenButton.Add_Click({Invoke-UiAction{Generate-RemoteToken}})
$Ui.RemoteCopyTokenButton.Add_Click({Invoke-UiAction{Copy-RemoteToken}})
$Ui.RemoteOpenButton.Add_Click({Invoke-UiAction{Start-Process ([string]$Ui.RemoteUrlText.Text)}})
$Ui.RemoteCopyVpnUrlButton.Add_Click({Invoke-UiAction{Copy-RemoteVpnUrl}})
$Ui.RemoteTestButton.Add_Click({Invoke-UiAction{Test-RemoteDashboardAccess}})
$Ui.RemoteStartServiceButton.Add_Click({Invoke-UiAction{$null=Register-RustRemoteTask -ServerRoot $ServerRoot;Refresh-RemoteAccess;Set-Activity 'Tableau de bord distant démarré.'}})
$Ui.RemoteStopServiceButton.Add_Click({Invoke-UiAction{$null=Unregister-RustRemoteTask -ServerRoot $ServerRoot;Refresh-RemoteAccess;Set-Activity 'Tableau de bord distant arrêté.'}})
$Ui.CatalogSyncButton.Add_Click({Invoke-UiAction{Sync-PluginCatalog}})
$Ui.CatalogAddSourceButton.Add_Click({Invoke-UiAction{Add-PluginCatalogSource}})
$Ui.CatalogSearchBox.Add_TextChanged({Invoke-UiAction{Refresh-AvailablePluginCatalog}})
$Ui.CatalogCategoryCombo.Add_SelectionChanged({Invoke-UiAction{Refresh-AvailablePluginCatalog}})
$Ui.AvailablePluginGrid.Add_SelectionChanged({Invoke-UiAction{Update-CatalogPluginInspector}})
$Ui.CatalogInstallButton.Add_Click({Invoke-UiAction{Start-CatalogPluginInstall}})
$Ui.CatalogRemoveButton.Add_Click({Invoke-UiAction{Remove-SelectedCatalogPlugin}})
$Ui.CatalogHomepageButton.Add_Click({Invoke-UiAction{$P=$Ui.AvailablePluginGrid.SelectedItem;if(-not$P-or[string]$P.Homepage-notmatch'^https://'){throw 'Page HTTPS absente.'};Start-Process ([string]$P.Homepage)}})
$Ui.CatalogOpenSourcesButton.Add_Click({Invoke-UiAction{$Path=Get-RustPluginCatalogSourcesPath -ServerRoot $ServerRoot;if(-not(Test-Path -LiteralPath $Path)){$null=Save-RustPluginCatalogSources -ServerRoot $ServerRoot -Store (Get-RustPluginCatalogSources -ServerRoot $ServerRoot)};Start-Process notepad.exe ('"'+$Path+'"')}})

$Ui.SimpleLocalActionButton.Add_Click({ Invoke-UiAction { Invoke-SimpleLocalAction } })
$Ui.SimpleFriendsActionButton.Add_Click({ Invoke-UiAction { Invoke-SimpleFriendsAction } })
$Ui.SimpleModsActionButton.Add_Click({ Open-SimpleDestination 11 })
$Ui.SimpleChangeServerButton.Add_Click({ Open-SimpleDestination 1 })
$Ui.SimpleHelpButton.Add_Click({
    Invoke-UiAction { Open-Onboarding }
})
$Ui.RunGlobalDiagnosticButton.Add_Click({ Invoke-UiAction { Refresh-GlobalDiagnostics } })
$Ui.RepairSelectedDiagnosticButton.Add_Click({ Invoke-UiAction { Repair-SelectedGlobalDiagnostic } })
$Ui.RepairGlobalDiagnosticButton.Add_Click({ Invoke-UiAction { Repair-GlobalDiagnostics } })
$Ui.ExportGlobalDiagnosticButton.Add_Click({ Invoke-UiAction { Export-GlobalDiagnostics } })
$Ui.SaveReleaseRepositoryButton.Add_Click({ Invoke-UiAction { Save-ReleaseRepository } })
$Ui.CheckControlCenterUpdateButton.Add_Click({ Invoke-UiAction { Check-ControlCenterUpdate } })
$Ui.InstallControlCenterUpdateButton.Add_Click({ Invoke-UiAction { Start-ControlCenterSelfUpdate } })
$Ui.RefreshUpdateBackupsButton.Add_Click({ Invoke-UiAction { Refresh-ControlCenterUpdateBackups } })
$Ui.RestoreControlCenterVersionButton.Add_Click({ Invoke-UiAction { Restore-ControlCenterVersion } })
$Ui.HostHealthRefreshButton.Add_Click({ Invoke-UiAction { Refresh-HostHealth } })
$Ui.HostHealthTaskManagerButton.Add_Click({ Invoke-UiAction { Start-Process taskmgr.exe } })
$Ui.HostHealthFirewallButton.Add_Click({ Invoke-UiAction { Start-Process control.exe '/name Microsoft.WindowsFirewall' } })
$Ui.HostHealthRepairButton.Add_Click({ Invoke-UiAction { Repair-SelectedHostHealth } })
$Ui.HostHealthOpenSettingsButton.Add_Click({ Invoke-UiAction { Start-Process 'ms-settings:about' } })
$Ui.OnboardingInstallButton.Add_Click({ Invoke-UiAction { Start-OnboardingInstallation } })
$Ui.OnboardingVanillaRadio.Add_Click({ Invoke-UiAction { Update-OnboardingEnvironmentDescription } })
$Ui.OnboardingCarbonRadio.Add_Click({ Invoke-UiAction { Update-OnboardingEnvironmentDescription } })
$Ui.OnboardingOxideRadio.Add_Click({ Invoke-UiAction { Update-OnboardingEnvironmentDescription } })
$Ui.OnboardingNetworkButton.Add_Click({ Invoke-UiAction { Test-OnboardingNetwork } })
$Ui.OnboardingCreateServerButton.Add_Click({ Invoke-UiAction { Open-ServerWizard -ReturnTab 18 } })
$Ui.OnboardingBackgroundButton.Add_Click({ Invoke-UiAction { Install-MaintenanceWorkerTask; Refresh-Onboarding } })
$Ui.OnboardingRepairButton.Add_Click({ Invoke-UiAction { Invoke-OnboardingRepair } })
$Ui.OnboardingDiagnosticButton.Add_Click({ Invoke-UiAction { Open-ControlCenterTab 17; Refresh-GlobalDiagnostics } })
$Ui.OnboardingLaterButton.Add_Click({ Invoke-UiAction { Dismiss-Onboarding } })
$Ui.OnboardingFinishButton.Add_Click({ Invoke-UiAction { Complete-Onboarding } })
$Ui.SideCopyButton.Add_Click({ Invoke-UiAction { Copy-FriendAddress } })
$Ui.SideRefreshAddressButton.Add_Click({
    Invoke-UiAction {
        # ACTUALISER revérifie aussi la box tout de suite, sans attendre la minute.
        $script:ReachCheckedAt = [datetime]::MinValue
        $null = Get-FriendCommand -ForceRefresh
        Update-RuntimeDisplay
        Set-Activity 'Adresse publique actualisee.'
    }
})
$Ui.LanguageCombo.Add_SelectionChanged({
    if ($script:InstanceRefreshGuard -or $null -eq $Ui.LanguageCombo.SelectedValue) { return }
    Invoke-UiAction { Apply-ControlCenterLanguage -Code ([string]$Ui.LanguageCombo.SelectedValue) }
})
$Ui.HeaderInstanceCombo.Add_SelectionChanged({ Invoke-UiAction { Select-InstanceFromHeader } })
$Ui.InstanceGrid.Add_SelectionChanged({ Invoke-UiAction { Select-InstanceFromGrid } })
$Ui.NewInstanceButton.Add_Click({ Invoke-UiAction { Open-ServerWizard } })
$Ui.DuplicateInstanceButton.Add_Click({ Invoke-UiAction { Create-ServerInstance -Duplicate } })
$Ui.WizardPresetLocalRadio.Add_Click({ Invoke-UiAction { Set-WizardPreset local } })
$Ui.WizardPresetFriendsRadio.Add_Click({ Invoke-UiAction { Set-WizardPreset friends } })
$Ui.WizardPresetCommunityRadio.Add_Click({ Invoke-UiAction { Set-WizardPreset community } })
$Ui.WizardAutoPortsCheck.Add_Click({ Invoke-UiAction { Update-WizardPortEditingState } })
$Ui.WizardMapTypeCombo.Add_SelectionChanged({ Invoke-UiAction { Update-WizardMapControls } })
$Ui.WizardRandomSeedButton.Add_Click({ $Ui.WizardSeedBox.Text = [string](Get-Random -Minimum 0 -Maximum 2147483647) })
$Ui.WizardMemoryBox.Add_TextChanged({ Update-WizardResourceText })
$Ui.WizardBackButton.Add_Click({ Invoke-UiAction { Move-ServerWizardBack } })
$Ui.WizardCancelButton.Add_Click({ Invoke-UiAction { Close-ServerWizard } })
$Ui.WizardNextButton.Add_Click({ Invoke-UiAction { Move-ServerWizardNext } })
$Ui.WizardSuccessServersButton.Add_Click({ Invoke-UiAction { Close-ServerWizard } })
$Ui.WizardSuccessCloseButton.Add_Click({ Invoke-UiAction { Close-ServerWizard } })
$Ui.WizardSuccessNetworkButton.Add_Click({
    Invoke-UiAction {
        Apply-InterfaceMode -Mode advanced
        Open-ControlCenterTab 9
        Refresh-NetworkDiagnostics
    }
})
$Ui.SaveInstanceButton.Add_Click({ Invoke-UiAction { Save-SelectedInstance } })
$Ui.RemoveInstanceButton.Add_Click({ Invoke-UiAction { Remove-SelectedInstance } })
$Ui.AllowMultiInstanceCheck.Add_Click({
    Invoke-UiAction {
        $Enabled = [bool]$Ui.AllowMultiInstanceCheck.IsChecked
        if ($Enabled -and -not (Confirm-Action "Le multi-instance est expérimental.`n`nChaque processus peut utiliser 5 à 8 Go de RAM. Carbon et certains plugins partagent leurs fichiers et peuvent mal fonctionner. Les ports doivent rester uniques.`n`nActiver quand même ?" 'Activer le multi-instance')) {
            $Ui.AllowMultiInstanceCheck.IsChecked = $false
            return
        }
        Set-RustMultiInstanceEnabled -ServerRoot $ServerRoot -Enabled $Enabled
        Refresh-Instances
    }
})
$Ui.DashLocalButton.Add_Click({ Invoke-UiAction { Start-SelectedInstance } })
$Ui.DashOnlineButton.Add_Click({ Select-AdvancedNav -Tab 1 })
$Ui.HeaderStartButton.Add_Click({
    Invoke-UiAction {
        $Instance = Get-SelectedServerInstance
        $Process = if ($Instance) { @(Get-RustRpgServerProcesses -ServerRoot $ServerRoot | Where-Object Identity -eq ([string]$Instance.identity)) | Select-Object -First 1 } else { $null }
        if ($Process) { Stop-SelectedInstance } else { Start-SelectedInstance }
    }
})
$Ui.DashUpdateButton.Add_Click({ Invoke-UiAction { Start-ServerUpdate } })
$Ui.DashCopyButton.Add_Click({ Invoke-UiAction { [Windows.Clipboard]::SetText((Get-SelectedConnectCommand)); Set-Activity 'Adresse du serveur copiée.' } })
$Ui.DashboardExtensionsButton.Add_Click({ Select-AdvancedNav -Tab 4 })
$Ui.ServerLocalButton.Add_Click({ Invoke-UiAction { Start-SelectedInstance } })
$Ui.ServerOnlineButton.Add_Click({ Invoke-UiAction { Start-EnabledInstances } })
$Ui.DashJoinButton.Add_Click({ Invoke-UiAction { Join-RustServer } })
$Ui.ServerJoinButton.Add_Click({ Invoke-UiAction { Join-RustServer } })
$Ui.DashStopButton.Add_Click({ Invoke-UiAction { Stop-SelectedInstance } })
$Ui.ServerStopButton.Add_Click({ Invoke-UiAction { Stop-SelectedInstance } })
$Ui.StopAllInstancesButton.Add_Click({ Invoke-UiAction { Stop-AllServerInstances } })
$Ui.SaveServerSettingsButton.Add_Click({ Invoke-UiAction { Save-ServerSettings } })

$Ui.MapIdentityCombo.Add_SelectionChanged({ Invoke-UiAction { Load-MapProfile } })
$Ui.MapTypeCombo.Add_SelectionChanged({ $Ui.MapUrlBox.IsEnabled = ((Get-SelectedText $Ui.MapTypeCombo) -eq 'Custom URL') })
$Ui.RandomSeedButton.Add_Click({ $Ui.MapSeedBox.Text = [string](Get-Random -Minimum 0 -Maximum 2147483647) })
$Ui.ApplyMapButton.Add_Click({ Invoke-UiAction { $null = Save-MapProfile } })
$Ui.GenerateMapButton.Add_Click({ Invoke-UiAction { Generate-NewMap } })
$Ui.MapLibraryGrid.Add_SelectionChanged({ Invoke-UiAction { Update-MapLibraryInspector } })
$Ui.ImportRustEditMapButton.Add_Click({ Invoke-UiAction { Import-RustEditMapFromDialog } })
$Ui.OpenMapLibraryButton.Add_Click({ Invoke-UiAction { $Path=Join-Path $ServerRoot 'data\maps\library';[IO.Directory]::CreateDirectory($Path)|Out-Null;Start-Process explorer.exe ('"'+$Path+'"') } })
$Ui.SaveMapLibraryUrlButton.Add_Click({ Invoke-UiAction { Save-SelectedMapPublicUrl } })
$Ui.ApplyImportedMapButton.Add_Click({ Invoke-UiAction { Apply-SelectedImportedMap } })
$Ui.RefreshArenaProfilesButton.Add_Click({ Invoke-UiAction { Refresh-ArenaProfiles } })
$Ui.ArenaProfileGrid.Add_SelectionChanged({ Invoke-UiAction { Update-ArenaProfileEditor } })
$Ui.GenerateArenaButton.Add_Click({ Invoke-UiAction { Generate-SelectedArena } })
$Ui.CleanupArenaButton.Add_Click({ Invoke-UiAction { Cleanup-SelectedArena } })

$Ui.CreateBackupButton.Add_Click({ Invoke-UiAction { Create-ManualBackup } })
$Ui.MapWipeButton.Add_Click({ Invoke-UiAction { Run-ManualWipe map } })
$Ui.FullWipeButton.Add_Click({ Invoke-UiAction { Run-ManualWipe full } })
$Ui.RefreshBackupsButton.Add_Click({ Invoke-UiAction { Refresh-Backups; Set-Activity 'Liste des sauvegardes actualisee.' } })
$Ui.VerifyBackupButton.Add_Click({ Invoke-UiAction { Verify-SelectedBackup } })
$Ui.RestoreBackupButton.Add_Click({ Invoke-UiAction { Restore-SelectedBackup } })
$Ui.OpenBackupsButton.Add_Click({ Start-Process explorer.exe ('"' + (Join-Path $ServerRoot 'backups\control-center') + '"') })
$Ui.ScheduleGrid.Add_SelectionChanged({ Invoke-UiAction { if ($Ui.ScheduleGrid.SelectedItem) { Load-MaintenanceScheduleEditor $Ui.ScheduleGrid.SelectedItem.Raw } } })
$Ui.ScheduleNameBox.Add_TextChanged({ Set-MaintenanceEditorDirty })
$Ui.ScheduleIdentityCombo.Add_SelectionChanged({ Set-MaintenanceEditorDirty })
$Ui.ScheduleActionCombo.Add_SelectionChanged({ Invoke-UiAction { Set-MaintenanceEditorDirty; Update-MaintenanceEditorState } })
$Ui.ScheduleRecurrenceCombo.Add_SelectionChanged({ Invoke-UiAction { Set-MaintenanceEditorDirty; Update-MaintenanceEditorState } })
$Ui.ScheduleDayCombo.Add_SelectionChanged({ Invoke-UiAction { Set-MaintenanceEditorDirty; Update-MaintenanceEditorState } })
$Ui.ScheduleTimeBox.Add_TextChanged({ Set-MaintenanceEditorDirty; Update-MaintenanceEditorState })
$Ui.ScheduleIntervalBox.Add_TextChanged({ Set-MaintenanceEditorDirty; Update-MaintenanceEditorState })
$Ui.ScheduleRetentionBox.Add_TextChanged({ Set-MaintenanceEditorDirty })
$Ui.ScheduleEnabledCheck.Add_Click({ Set-MaintenanceEditorDirty })
$Ui.ScheduleStopRestartCheck.Add_Click({ Set-MaintenanceEditorDirty })
$Ui.ScheduleResetPluginDataCheck.Add_Click({ Set-MaintenanceEditorDirty })
$Ui.ScheduleCleanMapsCheck.Add_Click({ Set-MaintenanceEditorDirty })
$Ui.NewScheduleButton.Add_Click({ Invoke-UiAction { New-MaintenanceScheduleEditor } })
$Ui.SaveScheduleButton.Add_Click({ Invoke-UiAction { Save-MaintenanceScheduleEditor } })
$Ui.ToggleScheduleButton.Add_Click({ Invoke-UiAction { Toggle-SelectedMaintenanceSchedule } })
$Ui.RunScheduleButton.Add_Click({ Invoke-UiAction { Run-SelectedMaintenanceSchedule } })
$Ui.DeleteScheduleButton.Add_Click({ Invoke-UiAction { Delete-SelectedMaintenanceSchedule } })
$Ui.InstallMaintenanceWorkerButton.Add_Click({ Invoke-UiAction { Install-MaintenanceWorkerTask } })
$Ui.RemoveMaintenanceWorkerButton.Add_Click({ Invoke-UiAction { Remove-MaintenanceWorkerTask } })

$Ui.RefreshPluginsButton.Add_Click({ Invoke-UiAction { Refresh-Plugins } })
$Ui.PluginGrid.Add_SelectionChanged({ Update-PluginSdkInspector })
$Ui.EnablePluginButton.Add_Click({ Invoke-UiAction { Set-SelectedPluginState $true } })
$Ui.DisablePluginButton.Add_Click({ Invoke-UiAction { Set-SelectedPluginState $false } })
$Ui.ReloadPluginButton.Add_Click({ Invoke-UiAction { Reload-SelectedPlugin } })
$Ui.ImportPluginButton.Add_Click({ Invoke-UiAction { Import-PluginFile } })
$Ui.InstallCarbonButton.Add_Click({ Invoke-UiAction { Start-CarbonInstall } })
$Ui.InstallOxideButton.Add_Click({ Invoke-UiAction { Start-OxideInstall } })
$Ui.PluginConfigButton.Add_Click({ Invoke-UiAction { Open-PluginConfig } })
$Ui.PluginSdkSaveButton.Add_Click({ Invoke-UiAction { Save-SelectedPluginSdkConfiguration } })
$Ui.PluginSdkOpenConfigButton.Add_Click({ Invoke-UiAction { Open-PluginConfig } })
$Ui.PluginSourceButton.Add_Click({ Invoke-UiAction { $Plugin = Get-SelectedPlugin; Start-Process notepad.exe ('"' + $Plugin.Path + '"') } })
$Ui.ArchivePluginButton.Add_Click({ Invoke-UiAction { Archive-SelectedPlugin } })

$Ui.ModeCapabilityGrid.Add_SelectionChanged({ Update-ModeInspector })
$Ui.ModeOpenConfigButton.Add_Click({ Invoke-UiAction { Open-SelectedModeConfig } })
$Ui.ModeReloadPluginButton.Add_Click({ Invoke-UiAction { Reload-SelectedModePlugin } })
$Ui.ModeRefreshButton.Add_Click({ Invoke-UiAction { Refresh-ModeStatus } })
$Ui.LobbyRebuildButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'lobby.rebuild' 'Reconstruire le lobby' } })
$Ui.ModePlayersButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'status' } })
$Ui.StartCtfButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'event.start ctf' } })
$Ui.StartDomButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'event.start domination' } })
$Ui.StartSndButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'event.start snd' } })
$Ui.StartExtractionButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'event.start extraction' } })
$Ui.StartZombieButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'zombie.force' } })
$Ui.StartGunGameButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'ggforce' } })
$Ui.StartTowerDefenseButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'td.force' } })
$Ui.StartTowerDefenseEndlessButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'td.endless' } })
$Ui.StartTournamentButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'duel.tournament.start 4' } })
$Ui.StartTrainingButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'training.force' } })
$Ui.StartSparringButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'training.force "" melee' } })
$Ui.StopTrainingButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'training.stop' "Arreter l'entrainement" } })
$Ui.StopEventButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'event.stop' 'Arreter le mode competitif en cours' } })
$Ui.StopZombieButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'zombie.stop' 'Arreter la partie Zombie' } })
$Ui.StopGunGameButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'gg.stop' 'Arreter la partie Gun Game' } })
$Ui.StopTowerDefenseButton.Add_Click({ Invoke-UiAction { Invoke-ModeAdminCommand 'td.stop' 'Arreter la partie Tower Defense' } })
$Ui.StopDuelButton.Add_Click({
    Invoke-UiAction {
        if (-not (Get-RustRpgServerState).Running) { throw "Le serveur n'est pas actif." }
        Invoke-AfterDisruptionCheck -ActionLabel 'Arreter les duels et le tournoi' -Continuation {
            Queue-ServerOperation -Operation command -Command 'duel.tournament.stop' -Label 'arret du tournoi' -OnSuccess {
                param($Response)
                Invoke-ModeAdminCommand 'duel.stop'
            }
        }
    }
})
$Ui.SaveRewardsButton.Add_Click({ Invoke-UiAction { Save-ModeRewards } })

$Ui.ConfigFileCombo.Add_SelectionChanged({ Invoke-UiAction { Load-SelectedConfig } })
$Ui.ReloadConfigButton.Add_Click({ Invoke-UiAction { Load-SelectedConfig } })
$Ui.ValidateConfigButton.Add_Click({ Invoke-UiAction { $null = Validate-SelectedConfig } })
$Ui.FormatConfigButton.Add_Click({ Invoke-UiAction { Format-SelectedConfig } })
$Ui.SaveConfigButton.Add_Click({ Invoke-UiAction { Save-SelectedConfig } })
$Ui.ConfigModeTabs.Add_SelectionChanged({
    if ($_.Source -ne $Ui.ConfigModeTabs -or $script:ConfigTabChangeGuard) { return }
    Invoke-UiAction {
        $script:ConfigTabChangeGuard = $true
        try {
            if ($Ui.ConfigModeTabs.SelectedIndex -eq 1) { Sync-VisualConfigToRaw }
            else { Load-VisualConfigFromRaw }
        }
        finally { $script:ConfigTabChangeGuard = $false }
    }
})

$Ui.RefreshPlayersButton.Add_Click({ Invoke-UiAction { Refresh-Players; Refresh-Bans; Refresh-ModerationLog } })
$Ui.KickPlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerSanction 'kick' } })
$Ui.BanPlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerSanction 'ban' } })
$Ui.HealPlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerComfort 'heal' } })
$Ui.FreePlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerComfort 'free' } })
$Ui.MessagePlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerComfort 'message' } })
$Ui.RefreshBansButton.Add_Click({ Invoke-UiAction { Refresh-Bans; Set-Activity 'Liste des bannis actualisee.' } })
$Ui.RefreshStatsButton.Add_Click({ Invoke-UiAction { Refresh-Stats } })
$Ui.PlayerStatsGrid.Add_SelectionChanged({ Invoke-UiAction { Show-PlayerCard } })
$Ui.SavePlayerNoteButton.Add_Click({ Invoke-UiAction { Save-PlayerNote } })
$Ui.UnbanPlayerButton.Add_Click({ Invoke-UiAction { Invoke-PlayerUnban } })
$Ui.RconSaveButton.Add_Click({ Invoke-UiAction { Invoke-RconAndDisplay 'server.save' } })
$Ui.SendRconButton.Add_Click({ Invoke-UiAction { if (-not $Ui.RconCommandBox.Text.Trim()) { throw 'Saisis une commande.' }; Invoke-RconAndDisplay $Ui.RconCommandBox.Text.Trim() } })
$Ui.RconCommandBox.Add_KeyDown({ if ($_.Key -eq [Windows.Input.Key]::Enter) { Invoke-UiAction { Invoke-RconAndDisplay $Ui.RconCommandBox.Text.Trim() } } })
$Ui.BroadcastButton.Add_Click({ Invoke-UiAction { $Message=$Ui.BroadcastBox.Text.Trim(); if(-not $Message){throw 'Saisis un message.'}; Invoke-RconAndDisplay ('say "' + $Message.Replace('"',"'") + '"') } })

$Ui.RunNetworkDiagnosticButton.Add_Click({ Invoke-UiAction { Refresh-NetworkDiagnostics } })
$Ui.CopyNetworkReportButton.Add_Click({ Invoke-UiAction { Copy-NetworkReport } })
$Ui.OpenUniversalNetworkGuideButton.Add_Click({
    Invoke-UiAction {
        $GuidePath = Join-Path $ServerRoot 'GUIDE-RESEAU-UNIVERSEL.html'
        if (-not (Test-Path -LiteralPath $GuidePath)) { throw 'Le guide reseau universel est introuvable.' }
        Start-Process -FilePath $GuidePath
        Set-Activity 'Guide reseau tous operateurs ouvert.'
    }
})
$Ui.RefreshNetworkAddressButton.Add_Click({
    Invoke-UiAction {
        $null = Get-FriendCommand -ForceRefresh
        Update-NetworkHeader
        Refresh-NetworkDiagnostics
    }
})
$Ui.OpenFirewallButton.Add_Click({ Invoke-UiAction { Start-Process -FilePath 'wf.msc' } })
$Ui.OpenNetworkLiveboxButton.Add_Click({ Invoke-UiAction { Start-Process (Join-Path $ServerRoot 'OUVRIR-REGLAGE-LIVEBOX.bat') } })
$Ui.NetworkDdnsSaveButton.Add_Click({ Invoke-UiAction { Save-NetworkAccessSettings } })
$Ui.NetworkDdnsTestButton.Add_Click({ Invoke-UiAction { Test-NetworkDdnsNow } })
$Ui.NetworkAccessSaveButton.Add_Click({ Invoke-UiAction { Save-NetworkAccessSettings } })
$Ui.NetworkCopyAlternativeCommandButton.Add_Click({ Invoke-UiAction { Copy-NetworkAlternativeCommand } })
$Ui.NetworkTailscaleInstallButton.Add_Click({ Invoke-UiAction { Install-TailscaleFromControlCenter } })
$Ui.NetworkTailscaleLoginButton.Add_Click({ Invoke-UiAction { Connect-TailscaleFromControlCenter } })
$Ui.NetworkTailscaleEnableButton.Add_Click({ Invoke-UiAction { Enable-TailscaleForRust } })
$Ui.NetworkTailscaleRefreshButton.Add_Click({ Invoke-UiAction { Refresh-TailscaleDisplay | Out-Null; Set-Activity (Get-LocalizedUiText 'État Tailscale actualisé.' 'Tailscale status refreshed.') } })
$Ui.NetworkTailscaleInviteButton.Add_Click({ Invoke-UiAction { Start-Process 'https://login.tailscale.com/admin/users'; Set-Activity (Get-LocalizedUiText "Création de l'invitation ouverte dans Tailscale." 'Tailscale invitation page opened.') } })
$Ui.NetworkTailscaleCopyGuideButton.Add_Click({ Invoke-UiAction { Copy-TailscaleFriendGuide } })
$Ui.NetworkOpenTunnelButton.Add_Click({ Invoke-UiAction { Start-Process 'https://playit.gg/support/run-a-game-server-without-port-forwarding' } })

$Ui.LogFileCombo.Add_SelectionChanged({ Invoke-UiAction { Load-SelectedLog } })
$Ui.RefreshLogsButton.Add_Click({ Invoke-UiAction { Refresh-LogFiles; Load-SelectedLog } })
$Ui.UpdateServerButton.Add_Click({ Invoke-UiAction { Start-ServerUpdate } })
$Ui.OpenServerFolderButton.Add_Click({ Start-Process explorer.exe ('"' + $ServerRoot + '"') })
$Ui.OpenLiveboxButton.Add_Click({ Start-Process (Join-Path $ServerRoot 'OUVRIR-REGLAGE-LIVEBOX.bat') })
$Ui.OpenInstructionsButton.Add_Click({ Start-Process notepad.exe ('"' + (Join-Path $ServerRoot 'INSTRUCTIONS-LANCEMENT.txt') + '"') })

$Ui.GlobalOperationOpenButton.Add_Click({ Invoke-UiAction { Open-ControlCenterTab 14 } })
$Ui.OperationRefreshButton.Add_Click({ Invoke-UiAction { Update-TrackedServerStartOperations; Refresh-OperationCenter } })
$Ui.OperationFilterAllButton.Add_Click({ Invoke-UiAction { Set-OperationFilter All } })
$Ui.OperationFilterRunningButton.Add_Click({ Invoke-UiAction { Set-OperationFilter Running } })
$Ui.OperationFilterSuccessButton.Add_Click({ Invoke-UiAction { Set-OperationFilter Succeeded } })
$Ui.OperationFilterFailedButton.Add_Click({ Invoke-UiAction { Set-OperationFilter Failed } })
$Ui.OperationHistoryGrid.Add_SelectionChanged({ Invoke-UiAction { Update-OperationDetail } })
$Ui.OperationCancelButton.Add_Click({ Invoke-UiAction { Cancel-ActiveTrackedOperation } })
$Ui.OperationActiveLogButton.Add_Click({ Invoke-UiAction { Open-TrackedOperationLog (Get-RustActiveTrackedOperation -ServerRoot $ServerRoot) } })
$Ui.OperationDetailLogButton.Add_Click({ Invoke-UiAction { Open-TrackedOperationLog (Get-SelectedTrackedOperation) } })
$Ui.OperationRetryButton.Add_Click({ Invoke-UiAction { Retry-SelectedOperation } })
$Ui.OperationDiagnosticButton.Add_Click({ Invoke-UiAction { Open-SelectedOperationDiagnostic } })

$StatusTimer = New-Object Windows.Threading.DispatcherTimer
$StatusTimer.Interval = [TimeSpan]::FromSeconds(5)
$StatusTimer.Add_Tick({
    Update-RuntimeDisplay
    # L'etat en direct ne coute deux appels RCON que sur la vue d'ensemble.
    if ($Ui.MainTabs.SelectedIndex -eq 0 -and $script:InterfaceMode -eq 'advanced' -and -not $CapturePath) {
        Invoke-UiAction { Refresh-DashboardLive }
    }
    if ($Ui.MainTabs.SelectedIndex -eq 19 -and -not $CapturePath) { Invoke-UiAction { Refresh-Supervision } }
    if ($Ui.MainTabs.SelectedIndex -eq 20 -and -not $CapturePath) { Invoke-UiAction { Refresh-RemoteAccess } }
    if ($Ui.MainTabs.SelectedIndex -eq 9 -and -not $CapturePath) { Invoke-UiAction { Refresh-TailscaleDisplay | Out-Null } }
    try { Complete-DdnsWorker } catch { Set-Activity ('DDNS : ' + $_.Exception.Message) }
})

$ServerOperationTimer = New-Object Windows.Threading.DispatcherTimer
$ServerOperationTimer.Interval = [TimeSpan]::FromMilliseconds(120)
$ServerOperationTimer.Add_Tick({ Complete-ServerOperation; Start-NextServerOperation })

$UpdateProgressTimer = New-Object Windows.Threading.DispatcherTimer
$UpdateProgressTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$UpdateProgressTimer.Add_Tick({ Invoke-UiAction { Update-ControlCenterUpdateProgress } })

$AutomaticUpdateCheckTimer = New-Object Windows.Threading.DispatcherTimer
$AutomaticUpdateCheckTimer.Interval = [TimeSpan]::FromSeconds(1)
$AutomaticUpdateCheckTimer.Add_Tick({ try { Complete-AutomaticControlCenterUpdateCheck } catch { Set-Activity ('Recherche de mise à jour : ' + $_.Exception.Message) } })

$OperationCenterTimer = New-Object Windows.Threading.DispatcherTimer
$OperationCenterTimer.Interval = [TimeSpan]::FromSeconds(1)
$OperationCenterTimer.Add_Tick({
    try {
        $HadActiveOperation = $null -ne (Get-RustActiveTrackedOperation -ServerRoot $ServerRoot)
        Update-TrackedServerStartOperations
        Sync-ControlCenterUpdateOperation
        if ($HadActiveOperation -or $null -ne (Get-RustActiveTrackedOperation -ServerRoot $ServerRoot)) { Refresh-OperationCenter }
        if ($Ui.MainTabs.SelectedIndex -eq 12) { Refresh-FriendTestPanel }
        Show-PendingOperationNotifications
    }
    catch { Set-Activity ('Suivi des opérations : ' + $_.Exception.Message) }
})

$MaintenanceTimer = New-Object Windows.Threading.DispatcherTimer
$MaintenanceTimer.Interval = [TimeSpan]::FromSeconds(30)
$MaintenanceTimer.Add_Tick({
    try {
        Start-DueMaintenanceWorker
        Start-DueDdnsWorker
        if ($Ui.MainTabs.SelectedIndex -eq 3 -and -not $script:MaintenanceEditorDirty) { Refresh-MaintenanceSchedules -SelectId $script:SelectedScheduleId }
    }
    catch { Set-Activity ('Planification : ' + $_.Exception.Message) }
})

$script:PendingRustJoinCommand = ''
$script:PendingRustJoinDeadline = [datetime]::MinValue
$RustJoinTimer = New-Object Windows.Threading.DispatcherTimer
$RustJoinTimer.Interval = [TimeSpan]::FromSeconds(1)
$RustJoinTimer.Add_Tick({ Invoke-UiAction { Complete-PendingRustJoin } })

if ($CapturePath) {
    if ($CaptureTab -eq 18) {
        $script:WizardNavigationGuard = $true
        try { $Ui.MainTabs.SelectedIndex = 18 }
        finally { $script:WizardNavigationGuard = $false }
    }
    elseif ($CaptureTab -eq 15) {
        $script:WizardNavigationGuard = $true
        try {
            $CaptureNavigation = if ($script:InterfaceMode -eq 'simple') { $Ui.SimpleNavigation } else { $Ui.Navigation }
            $CaptureServerTag = if ($script:InterfaceMode -eq 'simple') { 13 } else { 1 }
            for ($Index = 0; $Index -lt $CaptureNavigation.Items.Count; $Index++) {
                if ($null -ne $CaptureNavigation.Items[$Index].Tag -and [int]$CaptureNavigation.Items[$Index].Tag -eq $CaptureServerTag) { $CaptureNavigation.SelectedIndex = $Index; break }
            }
            $Ui.MainTabs.SelectedIndex = 15
        }
        finally { $script:WizardNavigationGuard = $false }
    }
    elseif ($script:InterfaceMode -eq 'advanced') {
        if (Get-NavSection $CaptureTab) { Select-AdvancedNav -Tab $CaptureTab }
        else { Select-AdvancedNav -Tab 0 }
    }
    else {
        $CaptureSimpleIndex = -1
        for ($Index = 0; $Index -lt $Ui.SimpleNavigation.Items.Count; $Index++) {
            if ([int]$Ui.SimpleNavigation.Items[$Index].Tag -eq $CaptureTab) { $CaptureSimpleIndex = $Index; break }
        }
        if ($CaptureSimpleIndex -ge 0) { $Ui.SimpleNavigation.SelectedIndex = $CaptureSimpleIndex }
        else { $Ui.SimpleNavigation.SelectedIndex = 0; $Ui.MainTabs.SelectedIndex = 0 }
    }
}

$Window.Add_ContentRendered({
    Invoke-UiAction {
        Refresh-Instances
        Load-MapProfile
        Refresh-MapLibrary
        Refresh-Backups
        Refresh-MaintenanceSchedules
        Refresh-Plugins
        Refresh-ArenaProfiles
        Refresh-ModeStatus
        Refresh-ConfigFiles
        Refresh-Players
        Refresh-Bans
        Refresh-ModerationLog
        Refresh-Stats
        Refresh-LogFiles
        Load-SelectedLog
        Initialize-OperationCenter
        Refresh-ControlCenterUpdateBackups
        if ($Ui.MainTabs.SelectedIndex -eq 19) { Refresh-Supervision }
        if ($Ui.MainTabs.SelectedIndex -eq 20) { Refresh-RemoteAccess }
        if ($Ui.MainTabs.SelectedIndex -eq 21) { Refresh-AvailablePluginCatalog }
        if ($Ui.MainTabs.SelectedIndex -eq 22) { Refresh-HostHealth }
        if ($Ui.MainTabs.SelectedIndex -eq 17 -or ($CapturePath -and $CaptureDiagnosticDemo)) { Refresh-GlobalDiagnostics }
        if ($Ui.MainTabs.SelectedIndex -eq 18 -or ($CapturePath -and $CaptureOnboardingDemo)) { Refresh-Onboarding }
        if ($CapturePath -and $V12InteractionQaPath) {
            Refresh-Onboarding
            $OnboardingSnapshot = [ordered]@{
                logoLoaded              = $null -ne $Ui.OnboardingLogoImage.Source
                installEnabled          = [bool]$Ui.OnboardingInstallButton.IsEnabled
                createServerEnabled     = [bool]$Ui.OnboardingCreateServerButton.IsEnabled
                backgroundButtonEnabled = [bool]$Ui.OnboardingBackgroundButton.IsEnabled
                repairVisible           = $Ui.OnboardingRepairButton.Visibility -eq [Windows.Visibility]::Visible
                repairCode              = [string]$script:OnboardingRepairCode
                finishEnabled           = [bool]$Ui.OnboardingFinishButton.IsEnabled
            }
            Open-ControlCenterTab 17
            Refresh-GlobalDiagnostics
            $DiagnosticSnapshot = [ordered]@{
                selectedTab = [int]$Ui.MainTabs.SelectedIndex
                rows        = [int]$Ui.GlobalDiagnosticGrid.Items.Count
                ok          = [int]$Ui.GlobalDiagnosticOkText.Text
                warnings    = [int]$Ui.GlobalDiagnosticWarningText.Text
                errors      = [int]$Ui.GlobalDiagnosticErrorText.Text
            }
            Open-Onboarding
            $QaResult = [ordered]@{ onboarding=$OnboardingSnapshot; diagnostic=$DiagnosticSnapshot; finalTab=[int]$Ui.MainTabs.SelectedIndex; header=[ordered]@{title=[string]$Ui.HeaderTitleText.Text;titleVisible=[string]$Ui.HeaderTitleText.Visibility;titleWidth=[math]::Round($Ui.HeaderTitleText.ActualWidth,1);logoLoaded=($null -ne $Ui.HeaderLogoImage.Source);logoVisible=[string]$Ui.HeaderLogoImage.Visibility;logoWidth=[math]::Round($Ui.HeaderLogoImage.ActualWidth,1)}; maintenanceRetentionVisible=($null -ne $Ui.ScheduleRetentionBox); backupVerificationVisible=($null -ne $Ui.VerifyBackupButton) }
            [IO.File]::WriteAllText($V12InteractionQaPath,($QaResult | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        }
        if($CapturePath -and $V8InteractionQaPath){
            Refresh-Supervision
            Refresh-RemoteAccess
            Refresh-AvailablePluginCatalog
            $Selected=Get-RustServerInstance -ServerRoot $ServerRoot
            $Isolation=Get-RustInstanceIsolationStatus -ServerRoot $ServerRoot -Instance $Selected
            $QaResult=[ordered]@{schema=(Get-RustMigrationStatus -ServerRoot $ServerRoot).TargetSchema;selectedInstance=[string]$Selected.id;isolation=[string]$Isolation.Mode;supervisionRows=[int]$Ui.SupervisionReadinessGrid.Items.Count;remoteUrl=[string]$Ui.RemoteUrlText.Text;remoteEnabled=[bool]$Ui.RemoteEnabledCheck.IsChecked;catalogRows=[int]$Ui.AvailablePluginGrid.Items.Count;catalogSources=@((Get-RustPluginCatalogSources -ServerRoot $ServerRoot).sources).Count;finalTab=[int]$Ui.MainTabs.SelectedIndex}
            [IO.File]::WriteAllText($V8InteractionQaPath,($QaResult|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($true))
        }
        if ($CapturePath -and $MaintenanceInteractionQaPath) {
            $ScheduleStorePath = Get-RustMaintenanceScheduleStorePath -ServerRoot $ServerRoot
            $StoreExistedBefore = Test-Path -LiteralPath $ScheduleStorePath
            New-MaintenanceScheduleEditor
            $Ui.ScheduleNameBox.Text = 'QA interaction non enregistrée'
            $Ui.ScheduleActionCombo.SelectedValue = 'MapWipe'
            $Ui.ScheduleRecurrenceCombo.SelectedValue = 'Interval'
            $Ui.ScheduleIntervalBox.Text = '36'
            Update-MaintenanceEditorState
            $QaResult = [ordered]@{
                editorDirty       = [bool]$script:MaintenanceEditorDirty
                action            = Get-SelectedText $Ui.ScheduleActionCombo
                recurrence        = Get-SelectedText $Ui.ScheduleRecurrenceCombo
                intervalEnabled   = [bool]$Ui.ScheduleIntervalBox.IsEnabled
                timeDisabled      = -not [bool]$Ui.ScheduleTimeBox.IsEnabled
                wipeSafetyEnabled = [bool]$Ui.ScheduleStopRestartCheck.IsEnabled
                saveButtonEnabled = [bool]$Ui.SaveScheduleButton.IsEnabled
                storeBefore       = $StoreExistedBefore
                storeAfter        = Test-Path -LiteralPath $ScheduleStorePath
            }
            [IO.File]::WriteAllText($MaintenanceInteractionQaPath,($QaResult | ConvertTo-Json),[Text.UTF8Encoding]::new($true))
        }
        if ($CapturePath -and $CaptureTab -eq 15) {
            Initialize-ServerWizard
            if ($CaptureWizardStep -eq 6) {
                $Ui.WizardSuccessText.Text = "Le profil '$CaptureWizardServerName' est prêt. Les serveurs existants et leurs mondes sont restés inchangés."
                $Ui.WizardSuccessAddressText.Text = "client.connect 127.0.0.1:$CaptureWizardServerPort"
                $Ui.WizardSuccessNetworkButton.Visibility = [Windows.Visibility]::Visible
            }
            if ($CaptureWizardStep -gt 1) { Set-WizardStep $CaptureWizardStep }
        }
        if ($CapturePath -and $CaptureTab -eq 14 -and $Ui.OperationHistoryGrid.Items.Count -gt 2) {
            $Ui.OperationHistoryGrid.SelectedIndex = 2
            Update-OperationDetail
        }
        Refresh-DashboardMetrics
        Refresh-DashboardLive
        Update-RuntimeDisplay
        Update-NetworkHeader
        Refresh-NetworkAccessSettings
        Refresh-FriendTestPanel
        if ($script:ActiveServerOperation -or $script:ServerOperationQueue.Count -gt 0) {
            Set-Activity 'Initialisation des donnees serveur en arriere-plan...'
        }
        else { Set-Activity (Get-LocalizedUiText 'Control Center prêt.' 'Control Center ready.') }
        if (-not $CapturePath) {
            $OnboardingState = Get-RustControlCenterState -ServerRoot $ServerRoot
            if (-not [bool]$OnboardingState.onboardingCompleted -and -not [bool]$OnboardingState.onboardingDismissed) { Open-Onboarding }
            Start-AutomaticControlCenterUpdateCheck
        }
    }
    # L'initialisation est terminee : les erreurs suivantes viennent d'une action
    # de l'utilisateur, il y a donc quelqu'un pour fermer la boite.
    $script:SuppressDialogs = $false
    $StatusTimer.Start()
    $ServerOperationTimer.Start()
    $UpdateProgressTimer.Start()
    $AutomaticUpdateCheckTimer.Start()
    $OperationCenterTimer.Start()
    $MaintenanceTimer.Start()
    if ($CapturePath) {
        if ($CaptureTab -eq 6) {
            # Le mode capture sert aussi de smoke-test : tous les fichiers sont
            # charges, aplatis, reconvertis et valides sans aucune ecriture.
            foreach ($ConfigItem in @($Ui.ConfigFileCombo.ItemsSource)) {
                $Ui.ConfigFileCombo.SelectedItem = $ConfigItem
                Load-SelectedConfig
                $null = Validate-SelectedConfig
            }
            if ($Ui.ConfigFileCombo.Items.Count -gt 0) {
                $Ui.ConfigFileCombo.SelectedIndex = 0
                Load-SelectedConfig
            }
        }
        $Window.UpdateLayout()
        $Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        $Width = [math]::Max(1,[int][math]::Ceiling($Window.ActualWidth))
        $Height = [math]::Max(1,[int][math]::Ceiling($Window.ActualHeight))
        $Bitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($Width,$Height,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $Bitmap.Render($Window)
        $Encoder = New-Object Windows.Media.Imaging.PngBitmapEncoder
        $Encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($Bitmap))
        $Stream = [IO.File]::Create($CapturePath)
        try { $Encoder.Save($Stream) } finally { $Stream.Dispose() }
        if ($ExitAfterCapture) { $Window.Close() }
    }
})

$Window.Add_Closed({
    $StatusTimer.Stop()
    $ServerOperationTimer.Stop()
    $UpdateProgressTimer.Stop()
    $AutomaticUpdateCheckTimer.Stop()
    $OperationCenterTimer.Stop()
    $MaintenanceTimer.Stop()
    $RustJoinTimer.Stop()
    if ($script:ActiveServerOperation) {
        try { $script:ActiveServerOperation.PowerShell.Stop() } catch {}
        try { $script:ActiveServerOperation.PowerShell.Dispose() } catch {}
    }
    $script:ServerOperationQueue.Clear()
    if ($script:PublicIpClient) { $script:PublicIpClient.Dispose() }
    if ($script:OperationNotifyIcon) {
        $script:OperationNotifyIcon.Visible = $false
        $script:OperationNotifyIcon.Dispose()
    }
    if ($MutexCreated) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
})

$null = $Window.ShowDialog()
