//
//  ServiceViewController.swift
//  Passepartout-iOS
//
//  Created by Davide De Rosa on 6/6/18.
//  Copyright (c) 2020 Davide De Rosa. All rights reserved.
//
//  https://github.com/passepartoutvpn
//
//  This file is part of Passepartout.
//
//  Passepartout is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Passepartout is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Passepartout.  If not, see <http://www.gnu.org/licenses/>.
//

import UIKit
import NetworkExtension
import MBProgressHUD
import CoreLocation
import TunnelKit
 
import Convenience

class ServiceViewController: UIViewController, StrongTableHost {
    @IBOutlet private weak var tableView: UITableView!

    @IBOutlet private weak var viewWelcome: UIView!

    @IBOutlet private weak var labelWelcome: UILabel!
    
    @IBOutlet private weak var itemEdit: UIBarButtonItem!
    
    private let locationManager = CLLocationManager()
    
    private var isPendingTrustedWiFi = false
    
    private let downloader = FileDownloader(
        temporaryURL: GroupConstants.App.cachesURL.appendingPathComponent("downloaded.tmp"),
        timeout: AppConstants.Services.timeout
    )

    private var profile: ConnectionProfile?

    private let service = TransientStore.shared.service
    
    private lazy var vpn = GracefulVPN(service: service)

    private weak var pendingRenameAction: UIAlertAction?

    private var lastInfrastructureUpdate: Date?
    
    private var shouldDeleteLogOnDisconnection = false

    private var currentDataCount: (Int, Int)?
    
    // MARK: Table
    
    var model: StrongTableModel<SectionType, RowType> = StrongTableModel()
    
    private let trustedNetworks = TrustedNetworksUI()
    
    // MARK: UIViewController

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func setProfile(_ profile: ConnectionProfile?, reloadingViews: Bool = true) {
        self.profile = profile
        vpn.profile = profile
        
        if let profile = profile {
            title = service.screenTitle(ProfileKey(profile))
        } else {
            title = nil
        }
        navigationItem.rightBarButtonItem = (profile?.context == .host) ? itemEdit : nil
        if reloadingViews {
            reloadModel()
            updateViewsIfNeeded()
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()

        // fall back to active profile
        if profile == nil {
            setProfile(service.activeProfile)
        }
        if let providerProfile = profile as? ProviderConnectionProfile {
            lastInfrastructureUpdate = InfrastructureFactory.shared.modificationDate(forName: providerProfile.name)
        }

        navigationItem.leftBarButtonItem = splitViewController?.displayModeButtonItem
        navigationItem.leftItemsSupplementBackButton = true

        labelWelcome.text = L10n.Core.Service.Welcome.message
        labelWelcome.apply(.current)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(applicationDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        nc.addObserver(self, selector: #selector(vpnDidUpdate), name: .VPNDidChangeStatus, object: nil)
        nc.addObserver(self, selector: #selector(vpnDidUpdate), name: .VPNDidReinstall, object: nil)
        if #available(iOS 13, *) {
            nc.addObserver(self, selector: #selector(intentDidUpdateService), name: IntentDispatcher.didUpdateService, object: nil)
        }
        nc.addObserver(self, selector: #selector(serviceDidUpdateDataCount(_:)), name: ConnectionService.didUpdateDataCount, object: nil)
        nc.addObserver(self, selector: #selector(productManagerDidReloadReceipt), name: ProductManager.didReloadReceipt, object: nil)
        nc.addObserver(self, selector: #selector(productManagerDidReviewPurchases), name: ProductManager.didReviewPurchases, object: nil)

        // run this no matter what
        // XXX: convenient here vs AppDelegate for updating table
        vpn.prepare() {
            self.reloadModel()
            self.updateViewsIfNeeded()
        }

        updateViewsIfNeeded()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        hideProfileIfDeleted()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        clearSelection()
        hideProfileIfDeleted()
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let sid = segue.identifier, let segueType = StoryboardSegue.Main(rawValue: sid) else {
            return
        }
        
        let destination = segue.destination
        
        switch segueType {
        case .accountSegueIdentifier:
            let vc = destination as? AccountViewController
            vc?.currentCredentials = service.credentials(for: uncheckedProfile)
            vc?.usernamePlaceholder = (profile as? ProviderConnectionProfile)?.infrastructure.defaults.username
            vc?.infrastructureName = (profile as? ProviderConnectionProfile)?.infrastructure.name
            vc?.delegate = self
            
        case .providerPoolSegueIdentifier:
            let vc = destination as? ProviderPoolViewController
            vc?.setInfrastructure(uncheckedProviderProfile.infrastructure, currentPoolId: uncheckedProviderProfile.poolId)
            vc?.favoriteGroupIds = uncheckedProviderProfile.favoriteGroupIds ?? []
            vc?.delegate = self
            
        case .endpointSegueIdentifier:
            let vc = destination as? EndpointViewController
            vc?.dataSource = profile
            vc?.delegate = self
            vc?.modificationDelegate = self
            
        case .providerPresetSegueIdentifier:
            let infra = uncheckedProviderProfile.infrastructure
            let presets: [InfrastructurePreset] = uncheckedProviderProfile.pool?.supportedPresetIds(in: uncheckedProviderProfile.infrastructure).map {
                return infra.preset(for: $0)!
            } ?? []

            let vc = destination as? ProviderPresetViewController
            vc?.presets = presets
            vc?.currentPresetId = uncheckedProviderProfile.presetId
            vc?.delegate = self
            
        case .hostParametersSegueIdentifier:
            let vc = destination as? ConfigurationViewController
            vc?.title = L10n.App.Service.Cells.Host.Parameters.caption
            vc?.initialConfiguration = uncheckedHostProfile.parameters.sessionConfiguration
            vc?.originalConfigurationURL = service.configurationURL(for: uncheckedHostProfile)
            vc?.delegate = self
            
        case .networkSettingsSegueIdentifier:
            let vc = destination as? NetworkSettingsViewController
            vc?.title = L10n.Core.NetworkSettings.title
            vc?.profile = profile
            
        case .serverNetworkSegueIdentifier:
            break
            
        case .debugLogSegueIdentifier:
            break
        }
    }
    
    // MARK: Actions
    
    func hideProfileIfDeleted() {
        guard let profile = profile else {
            return
        }
        if !service.containsProfile(profile) {
            setProfile(nil)
        }
    }
    
    // XXX: outlets can be nil here!
    private func updateViewsIfNeeded() {
        tableView?.reloadData()
        viewWelcome?.isHidden = (profile != nil)
    }
    
    private func activateProfile() {
        service.activateProfile(uncheckedProfile)

        // for vpn methods to work, must update .profile to currently active profile
        vpn.profile = uncheckedProfile
        vpn.disconnect { (error) in
            self.reloadModel()
            self.updateViewsIfNeeded()
        }
    }

    @IBAction private func renameProfile() {
        let alert = UIAlertController.asAlert(L10n.Core.Service.Alerts.Rename.title, nil)
        alert.addTextField { (field) in
            field.text = self.service.screenTitle(ProfileKey(self.uncheckedProfile))
            field.applyProfileId(.current)
            field.delegate = self
        }
        pendingRenameAction = alert.addPreferredAction(L10n.Core.Global.ok) {
            guard let newTitle = alert.textFields?.first?.text else {
                return
            }
            self.doRenameCurrentProfile(to: newTitle)
        }
        alert.addCancelAction(L10n.Core.Global.cancel)
        pendingRenameAction?.isEnabled = false
        present(alert, animated: true, completion: nil)
    }
    
    private func doRenameCurrentProfile(to newTitle: String) {
        guard let profile = profile else {
            return
        }
        service.renameProfile(profile, to: newTitle)
        setProfile(profile, reloadingViews: false)
    }
    
    private func toggleVpnService(cell: ToggleTableViewCell) {
        if cell.isOn {
            if #available(iOS 12, *) {
                let title = service.screenTitle(ProfileKey(uncheckedProfile))
                IntentDispatcher.donateConnection(with: uncheckedProfile, title: title)
            }
            guard !service.needsCredentials(for: uncheckedProfile) else {
                let alert = UIAlertController.asAlert(
                    L10n.App.Service.Sections.Vpn.header,
                    L10n.Core.Service.Alerts.CredentialsNeeded.message
                )
                alert.addCancelAction(L10n.Core.Global.ok) {
                    cell.setOn(false, animated: true)
                }
                present(alert, animated: true, completion: nil)
                return
            }
            vpn.reconnect { (error) in
                guard error == nil else {

                    // XXX: delay to avoid weird toggle state
                    delay {
                        cell.setOn(false, animated: true)
                        if error as? ApplicationError == .externalResources {
                            self.requireDownload()
                        }
                    }
                    return
                }
                self.reloadModel()
                self.updateViewsIfNeeded()
            }
        } else {
            if #available(iOS 12, *) {
                IntentDispatcher.donateDisableVPN()
            }
            vpn.disconnect { (error) in
                self.reloadModel()
                self.updateViewsIfNeeded()
            }
        }
    }
    
    private func confirmVpnReconnection() {
        guard vpn.status == .disconnected else {
            let alert = UIAlertController.asAlert(
                L10n.Core.Service.Cells.ConnectionStatus.caption,
                L10n.Core.Service.Alerts.ReconnectVpn.message
            )
            alert.addPreferredAction(L10n.Core.Global.ok) {
                self.vpn.reconnect(completionHandler: nil)
            }
            alert.addCancelAction(L10n.Core.Global.cancel)
            present(alert, animated: true, completion: nil)
            return
        }
        vpn.reconnect(completionHandler: nil)
    }
    
    private func refreshProviderInfrastructure() {
        let name = uncheckedProviderProfile.name
        
        let hud = HUD(view: view.window!)
        let isUpdating = InfrastructureFactory.shared.update(name, notBeforeInterval: AppConstants.Services.minimumUpdateInterval) { (response, error) in
            hud.hide()
            guard let response = response else {
                return
            }
            self.lastInfrastructureUpdate = response.1
            self.tableView.reloadData()
        }
        if !isUpdating {
            hud.hide()
        }
    }
    
    private func toggleDisconnectsOnSleep(_ isOn: Bool) {
        service.preferences.disconnectsOnSleep = !isOn
        if vpn.isEnabled {
            vpn.reinstall(completionHandler: nil)
        }
    }
    
    private func toggleResolvesHostname(_ isOn: Bool) {
        service.preferences.resolvesHostname = isOn
        if vpn.isEnabled {
            guard vpn.status == .disconnected else {
                confirmVpnReconnection()
                return
            }
            vpn.reinstall(completionHandler: nil)
        }
    }
    
    private func trustMobileNetwork(cell: ToggleTableViewCell) {
        guard ProductManager.shared.isEligible(forFeature: .trustedNetworks) else {
            delay {
                cell.setOn(false, animated: true)
            }
            presentPurchaseScreen(forProduct: .trustedNetworks)
            return
        }

        if #available(iOS 12, *) {
            IntentDispatcher.donateTrustCellularNetwork()
            IntentDispatcher.donateUntrustCellularNetwork()
        }

        trustedNetworks.setMobile(cell.isOn)
    }
    
    private func trustCurrentWiFi() {
        guard ProductManager.shared.isEligible(forFeature: .trustedNetworks) else {
            presentPurchaseScreen(forProduct: .trustedNetworks)
            return
        }

        if #available(iOS 13, *) {
            let auth = CLLocationManager.authorizationStatus()
            switch auth {
            case .authorizedAlways, .authorizedWhenInUse:
                break
                
            case .denied:
                isPendingTrustedWiFi = false
                let alert = UIAlertController.asAlert(
                    L10n.App.Service.Cells.TrustedAddWifi.caption,
                    L10n.App.Service.Alerts.Location.Message.denied
                )
                alert.addCancelAction(L10n.Core.Global.ok)
                alert.addPreferredAction(L10n.App.Service.Alerts.Location.Button.settings) {
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
                }
                present(alert, animated: true, completion: nil)
                return
                
            default:
                isPendingTrustedWiFi = true
                locationManager.delegate = self
                locationManager.requestWhenInUseAuthorization()
                return
            }
        }

        if #available(iOS 12, *) {
            IntentDispatcher.donateTrustCurrentNetwork()
            IntentDispatcher.donateUntrustCurrentNetwork()
        }

        guard trustedNetworks.addCurrentWifi() else {
            let alert = UIAlertController.asAlert(
                L10n.Core.Service.Sections.Trusted.header,
                L10n.Core.Service.Alerts.Trusted.NoNetwork.message
            )
            alert.addCancelAction(L10n.Core.Global.ok)
            present(alert, animated: true, completion: nil)
            return
        }
    }
    
    private func toggleTrustWiFi(cell: ToggleTableViewCell, at row: Int) {
        guard ProductManager.shared.isEligible(forFeature: .trustedNetworks) else {
            delay {
                cell.setOn(false, animated: true)
            }
            presentPurchaseScreen(forProduct: .trustedNetworks)
            return
        }

        if cell.isOn {
            trustedNetworks.enableWifi(at: row)
        } else {
            trustedNetworks.disableWifi(at: row)
        }
    }
    
    private func toggleTrustedConnectionPolicy(_ isOn: Bool, sender: ToggleTableViewCell) {
        let completionHandler: () -> Void = {
            self.uncheckedProfile.trustedNetworks.policy = isOn ? .disconnect : .ignore
            if self.vpn.isEnabled {
                self.vpn.reinstall(completionHandler: nil)
            }
        }
        guard isOn else {
            completionHandler()
            return
        }
        guard vpn.isEnabled else {
            completionHandler()
            return
        }
        let alert = UIAlertController.asAlert(
            L10n.Core.Service.Sections.Trusted.header,
            L10n.Core.Service.Alerts.Trusted.WillDisconnectPolicy.message
        )
        alert.addPreferredAction(L10n.Core.Global.ok) {
            completionHandler()
        }
        alert.addCancelAction(L10n.Core.Global.cancel) {
            sender.setOn(false, animated: true)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func confirmPotentialTrustedDisconnection(at rowIndex: Int?, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController.asAlert(
            L10n.Core.Service.Sections.Trusted.header,
            L10n.Core.Service.Alerts.Trusted.WillDisconnectTrusted.message
        )
        alert.addPreferredAction(L10n.Core.Global.ok) {
            completionHandler()
        }
        alert.addCancelAction(L10n.Core.Global.cancel) {
            guard let rowIndex = rowIndex else {
                return
            }
            let indexPath = IndexPath(row: rowIndex, section: self.trustedSectionIndex)
            let cell = self.tableView.cellForRow(at: indexPath) as? ToggleTableViewCell
            cell?.setOn(false, animated: true)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func testInternetConnectivity() {
        let hud = HUD(view: view.window!)
        Utils.checkConnectivityURL(AppConstants.Services.connectivityURL, timeout: AppConstants.Services.connectivityTimeout) {
            hud.hide()

            let V = L10n.Core.Service.Alerts.TestConnectivity.Messages.self
            let alert = UIAlertController.asAlert(
                L10n.Core.Service.Alerts.TestConnectivity.title,
                $0 ? V.success : V.failure
            )
            alert.addCancelAction(L10n.Core.Global.ok)
            self.present(alert, animated: true, completion: nil)
        }
    }
    
//    private func displayDataCount() {
//        guard vpn.isEnabled else {
//            let alert = UIAlertController.asAlert(
//                L10n.Core.Service.Cells.DataCount.caption,
//                L10n.Core.Service.Alerts.DataCount.Messages.notAvailable
//            )
//            alert.addCancelAction(L10n.Core.Global.ok)
//            present(alert, animated: true, completion: nil)
//            return
//        }
//
//        vpn.requestBytesCount {
//            let message: String
//            if let count = $0 {
//                message = L10n.Core.Service.Alerts.DataCount.Messages.current(Int(count.0), Int(count.1))
//            } else {
//                message = L10n.Core.Service.Alerts.DataCount.Messages.notAvailable
//            }
//            let alert = UIAlertController.asAlert(
//                L10n.Core.Service.Cells.DataCount.caption,
//                message
//            )
//            alert.addCancelAction(L10n.Core.Global.ok)
//            self.present(alert, animated: true, completion: nil)
//        }
//    }
    
    private func discloseServerConfiguration() {
        let caption = L10n.Core.Service.Cells.ServerConfiguration.caption
        tryRequestServerConfiguration(withCaption: caption) { [weak self] in
            let vc = StoryboardScene.Main.configurationIdentifier.instantiate()
            vc.title = caption
            vc.initialConfiguration = $0
            vc.isServerPushed = true
            self?.navigationController?.pushViewController(vc, animated: true)
        }
    }

    private func discloseServerNetwork() {
        let caption = L10n.Core.Service.Cells.ServerNetwork.caption
        tryRequestServerConfiguration(withCaption: caption) { [weak self] in
            let vc = StoryboardScene.Main.serverNetworkViewController.instantiate()
            vc.title = caption
            vc.configuration = $0
            self?.navigationController?.pushViewController(vc, animated: true)
        }
    }

    private func tryRequestServerConfiguration(withCaption caption: String, completionHandler: @escaping (OpenVPN.Configuration) -> Void) {
        vpn.requestServerConfiguration { [weak self] in
            guard let cfg = $0 as? OpenVPN.Configuration else {
                let alert = UIAlertController.asAlert(
                    caption,
                    L10n.Core.Service.Alerts.Configuration.disconnected
                )
                alert.addCancelAction(L10n.Core.Global.ok)
                self?.present(alert, animated: true, completion: nil)
                return
            }
            completionHandler(cfg)
        }
    }

    private func togglePrivateDataMasking(cell: ToggleTableViewCell) {
        let handler = {
            TransientStore.masksPrivateData = cell.isOn
            self.service.baseConfiguration = TransientStore.baseVPNConfiguration.build()
        }
        
        guard vpn.status == .disconnected else {
            let alert = UIAlertController.asAlert(
                L10n.Core.Service.Cells.MasksPrivateData.caption,
                L10n.Core.Service.Alerts.MasksPrivateData.Messages.mustReconnect
            )
            alert.addDestructiveAction(L10n.Core.Service.Alerts.Buttons.reconnect) {
                handler()
                self.shouldDeleteLogOnDisconnection = true
                self.vpn.reconnect(completionHandler: nil)
            }
            alert.addCancelAction(L10n.Core.Global.cancel) {
                cell.setOn(!cell.isOn, animated: true)
            }
            present(alert, animated: true, completion: nil)
            return
        }
        
        handler()
        service.eraseVpnLog()
        shouldDeleteLogOnDisconnection = false
    }

    private func reportConnectivityIssue() {
        let issue = Issue(debugLog: true, profile: uncheckedProfile)
        IssueReporter.shared.present(in: self, withIssue: issue)
    }
    
    private func requireDownload() {
        guard let providerProfile = profile as? ProviderConnectionProfile else {
            return
        }
        guard let downloadURL = AppConstants.URLs.externalResources[providerProfile.name] else {
            return
        }
        
        let alert = UIAlertController.asAlert(
            L10n.Core.Service.Alerts.Download.title,
            L10n.Core.Service.Alerts.Download.message(providerProfile.name)
        )
        alert.addCancelAction(L10n.Core.Global.cancel)
        alert.addPreferredAction(L10n.Core.Global.ok) {
            self.confirmDownload(URL(string: downloadURL)!)
        }
        present(alert, animated: true, completion: nil)
    }
    
    private func confirmDownload(_ url: URL) {
        _ = downloader.download(url: url, in: view) { (url, error) in
            self.handleDownloadedProviderResources(url: url, error: error)
        }
    }
    
    private func handleDownloadedProviderResources(url: URL?, error: Error?) {
        guard let url = url else {
            let alert = UIAlertController.asAlert(
                L10n.Core.Service.Alerts.Download.title,
                L10n.Core.Service.Alerts.Download.failed(error?.localizedDescription ?? "")
            )
            alert.addCancelAction(L10n.Core.Global.ok)
            present(alert, animated: true, completion: nil)
            return
        }

        let hud = HUD(view: view.window!, label: L10n.Core.Service.Alerts.Download.Hud.extracting)
        hud.show()
        uncheckedProviderProfile.name.importExternalResources(from: url) {
            hud.hide()
        }
    }
    
    // MARK: Notifications
    
    @objc private func vpnDidUpdate() {
        reloadVpnStatus()
        
        guard let status = vpn.status else {
            return
        }
        switch status {
        case .connected:
            Reviewer.shared.reportEvent()

        case .disconnected:
            if shouldDeleteLogOnDisconnection {
                service.eraseVpnLog()
                shouldDeleteLogOnDisconnection = false
            }
            
        default:
            break
        }
    }
    
    @objc private func intentDidUpdateService() {
        setProfile(service.activeProfile)
    }
    
    @objc private func applicationDidBecomeActive() {
        reloadModel()
        updateViewsIfNeeded()
    }
    
    @objc private func serviceDidUpdateDataCount(_ notification: Notification) {
        guard let dataCount = notification.userInfo?[ConnectionService.NotificationKeys.dataCount] as? (Int, Int) else {
            return
        }
        refreshDataCount(dataCount)
    }
    
    @objc private func productManagerDidReloadReceipt() {
        reloadModel()
        tableView.reloadData()
    }
    
    @objc private func productManagerDidReviewPurchases() {
        hideProfileIfDeleted()
    }
}

// MARK: -

extension ServiceViewController: UITableViewDataSource, UITableViewDelegate, ToggleTableViewCellDelegate {
    enum SectionType {
        case vpn
        
        case authentication
        
        case hostProfile
        
        case configuration
        
        case providerInfrastructure
        
        case vpnResolvesHostname
        
        case vpnSurvivesSleep
        
        case trusted
        
        case trustedPolicy
        
        case diagnostics
        
        case feedback
    }
    
    enum RowType: Int {
        case useProfile
        
        case vpnService
        
        case connectionStatus
        
        case reconnect

        case account
        
        case endpoint
        
        case providerPool
        
        case providerPreset
        
        case providerRefresh
        
        case hostParameters
        
        case networkSettings
        
        case vpnResolvesHostname
        
        case vpnSurvivesSleep
        
        case trustedMobile
        
        case trustedWiFi
        
        case trustedAddCurrentWiFi
        
        case trustedPolicy
        
        case testConnectivity
        
        case dataCount
        
        case serverConfiguration
        
        case serverNetwork
        
        case debugLog
        
        case masksPrivateData
        
        case faq
        
        case reportIssue
    }

    private var trustedSectionIndex: Int {
        return model.index(ofSection: .trusted)
    }
    
    private var statusIndexPath: IndexPath? {
        return model.indexPath(forRow: .connectionStatus, ofSection: .vpn)
    }
    
    private var dataCountIndexPath: IndexPath? {
        return model.indexPath(forRow: .dataCount, ofSection: .diagnostics)
    }
    
    private var endpointIndexPath: IndexPath {
        guard let ip = model.indexPath(forRow: .endpoint, ofSection: .configuration) else {
            fatalError("Could not locate endpointIndexPath")
        }
        return ip
    }
    
    private var providerPresetIndexPath: IndexPath {
        guard let ip = model.indexPath(forRow: .providerPreset, ofSection: .configuration) else {
            fatalError("Could not locate presetIndexPath")
        }
        return ip
    }
    
    private func mappedTrustedNetworksRow(_ from: TrustedNetworksUI.RowType) -> RowType {
        switch from {
        case .trustsMobile:
            return .trustedMobile
            
        case .trustedWiFi:
            return .trustedWiFi
            
        case .addCurrentWiFi:
            return .trustedAddCurrentWiFi
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return model.numberOfSections
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return model.header(forSection: section)
    }
    
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        let rows = model.rows(forSection: section)
        if rows.contains(.providerRefresh), let date = lastInfrastructureUpdate {
            return L10n.Core.Service.Sections.ProviderInfrastructure.footer(date.timestamp)
        }
        return model.footer(forSection: section)
    }
    
    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return model.headerHeight(for: section)
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return model.numberOfRows(forSection: section)
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = model.row(at: indexPath)
        switch row {
        case .useProfile:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(.current)
            cell.leftText = L10n.App.Service.Cells.UseProfile.caption
            return cell
            
        case .vpnService:
            guard service.isActiveProfile(uncheckedProfile) else {
                fatalError("Do not show vpnService in non-active profile")
            }

            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.App.Service.Cells.VpnService.caption
            cell.isOn = vpn.isEnabled
            return cell
            
        case .connectionStatus:
            guard service.isActiveProfile(uncheckedProfile) else {
                fatalError("Do not show connectionStatus in non-active profile")
            }
            
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyVPN(.current, with: vpn.isEnabled ? vpn.status : nil, error: service.vpnLastError)
            cell.leftText = L10n.Core.Service.Cells.ConnectionStatus.caption
            cell.accessoryType = .none
            cell.isTappable = false
            return cell
            
        case .reconnect:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(.current)
            cell.leftText = L10n.Core.Service.Cells.Reconnect.caption
            cell.accessoryType = .none
            cell.isTappable = !service.needsCredentials(for: uncheckedProfile) && vpn.isEnabled
            return cell

        // shared cells
            
        case .account:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Account.title
            cell.rightText = profile?.username
            return cell

        case .endpoint:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Endpoint.title

            let V = L10n.Core.Global.Values.self
            if let provider = profile as? ProviderConnectionProfile {
                cell.rightText = provider.usesProviderEndpoint ? V.manual : V.automatic
            } else {
                cell.rightText = profile?.mainAddress
            }
            return cell
            
        case .networkSettings:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.NetworkSettings.title
            return cell
            
        // provider cells
            
        case .providerPool:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.Provider.Pool.caption
            cell.rightText = uncheckedProviderProfile.pool?.localizedId
            return cell
            
        case .providerPreset:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.Provider.Preset.caption
            cell.rightText = uncheckedProviderProfile.preset?.name // XXX: localize?
            return cell
            
        case .providerRefresh:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(.current)
            cell.leftText = L10n.App.Service.Cells.Provider.Refresh.caption
            return cell
            
        // host cells
            
        case .hostParameters:
            let parameters = uncheckedHostProfile.parameters
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.App.Service.Cells.Host.Parameters.caption
            if !parameters.sessionConfiguration.fallbackCipher.embedsDigest {
                cell.rightText = "\(parameters.sessionConfiguration.fallbackCipher.genericName) / \(parameters.sessionConfiguration.fallbackDigest.genericName)"
            } else {
                cell.rightText = parameters.sessionConfiguration.fallbackCipher.genericName
            }
            return cell

        // VPN preferences
            
        case .vpnResolvesHostname:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Core.Service.Cells.VpnResolvesHostname.caption
            cell.isOn = service.preferences.resolvesHostname
            return cell
            
        case .vpnSurvivesSleep:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Core.Service.Cells.VpnSurvivesSleep.caption
            cell.isOn = !service.preferences.disconnectsOnSleep
            return cell
            
        case .trustedMobile:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Core.Service.Cells.TrustedMobile.caption
            cell.isOn = uncheckedProfile.trustedNetworks.includesMobile
            return cell
            
        case .trustedWiFi:
            let wifi = trustedNetworks.wifi(at: indexPath.row)
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = wifi.0
            cell.isOn = wifi.1
            return cell
            
        case .trustedAddCurrentWiFi:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.applyAction(.current)
            cell.leftText = L10n.App.Service.Cells.TrustedAddWifi.caption
            return cell

        case .trustedPolicy:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Core.Service.Cells.TrustedPolicy.caption
            cell.isOn = (uncheckedProfile.trustedNetworks.policy == .disconnect)
            return cell
            
        // diagnostics
            
        case .testConnectivity:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.TestConnectivity.caption
            return cell

        case .dataCount:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.DataCount.caption
            if let count = currentDataCount, vpn.status == .connected {
                let down = count.0.dataUnitDescription
                let up = count.1.dataUnitDescription
                cell.rightText = "↓\(down) / ↑\(up)"
            } else {
                cell.rightText = L10n.Core.Service.Cells.DataCount.none
            }
            cell.accessoryType = .none
            cell.isTappable = false
            return cell
            
        case .serverConfiguration:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText =  L10n.Core.Service.Cells.ServerConfiguration.caption
            return cell

        case .serverNetwork:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText =  L10n.Core.Service.Cells.ServerNetwork.caption
            return cell

        case .debugLog:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.DebugLog.caption
            return cell
            
        case .masksPrivateData:
            let cell = Cells.toggle.dequeue(from: tableView, for: indexPath, tag: row.rawValue, delegate: self)
            cell.caption = L10n.Core.Service.Cells.MasksPrivateData.caption
            cell.isOn = TransientStore.masksPrivateData
            return cell
            
        // feedback

        case .faq:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.About.Cells.Faq.caption
            return cell
            
        case .reportIssue:
            let cell = Cells.setting.dequeue(from: tableView, for: indexPath)
            cell.leftText = L10n.Core.Service.Cells.ReportIssue.caption
            return cell
        }
    }
    
//    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
//        cell.isSelected = (indexPath == lastSelectedIndexPath)
//    }
    
    // MARK: Actions
    
    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let cell = tableView.cellForRow(at: indexPath) else {
            return nil
        }
        if let settingCell = cell as? SettingTableViewCell {
            guard settingCell.isTappable else {
                return nil
            }
        }
        guard handle(row: model.row(at: indexPath), cell: cell) else {
            return nil
        }
        return indexPath
    }
    
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return model.row(at: indexPath) == .trustedWiFi
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        precondition(indexPath.section == model.index(ofSection: .trusted))
        trustedNetworks.removeWifi(at: indexPath.row)
    }
    
    func toggleCell(_ cell: ToggleTableViewCell, didToggleToValue value: Bool) {
        guard let item = RowType(rawValue: cell.tag) else {
            return
        }
        handle(row: item, cell: cell)
    }

    // true if enters subscreen
    private func handle(row: RowType, cell: UITableViewCell) -> Bool {
        switch row {
        case .useProfile:
            activateProfile()
            
        case .reconnect:
            confirmVpnReconnection()
            
        case .account:
            perform(segue: StoryboardSegue.Main.accountSegueIdentifier, sender: cell)
            return true
            
        case .endpoint:
            perform(segue: StoryboardSegue.Main.endpointSegueIdentifier, sender: cell)
            return true
            
        case .providerPool:
            perform(segue: StoryboardSegue.Main.providerPoolSegueIdentifier, sender: cell)
            return true

        case .providerPreset:
            perform(segue: StoryboardSegue.Main.providerPresetSegueIdentifier, sender: cell)
            return true
            
        case .providerRefresh:
            refreshProviderInfrastructure()
            return false
            
        case .hostParameters:
            perform(segue: StoryboardSegue.Main.hostParametersSegueIdentifier, sender: cell)
            return true
            
        case .networkSettings:
            perform(segue: StoryboardSegue.Main.networkSettingsSegueIdentifier, sender: cell)
            return true
            
        case .trustedAddCurrentWiFi:
            trustCurrentWiFi()
            
        case .testConnectivity:
            testInternetConnectivity()
            
//        case .dataCount:
//            displayDataCount()
            
        case .serverConfiguration:
            discloseServerConfiguration()
            
        case .serverNetwork:
            discloseServerNetwork()

        case .debugLog:
            perform(segue: StoryboardSegue.Main.debugLogSegueIdentifier, sender: cell)
            return true
            
        case .faq:
            visitURL(AppConstants.URLs.faq)
            
        case .reportIssue:
            reportConnectivityIssue()
            
        default:
            break
        }
        return false
    }
    
    private func handle(row: RowType, cell: ToggleTableViewCell) {
        switch row {
        case .vpnService:
            toggleVpnService(cell: cell)
            
        case .vpnResolvesHostname:
            toggleResolvesHostname(cell.isOn)
            
        case .vpnSurvivesSleep:
            toggleDisconnectsOnSleep(cell.isOn)
            
        case .trustedMobile:
            trustMobileNetwork(cell: cell)
            
        case .trustedWiFi:
            guard let indexPath = tableView.indexPath(for: cell) else {
                return
            }
            toggleTrustWiFi(cell: cell, at: indexPath.row)
            
        case .trustedPolicy:
            toggleTrustedConnectionPolicy(cell.isOn, sender: cell)
            
        case .masksPrivateData:
            togglePrivateDataMasking(cell: cell)
            
        default:
            break
        }
    }
    
    // MARK: Updates

    func reloadModel() {
        model.clear()
        
        guard let profile = profile else {
            return
        }
//        assert(profile != nil, "Profile not set")
        
        let isActiveProfile = service.isActiveProfile(profile)
        let isProvider = (profile as? ProviderConnectionProfile) != nil
        
        // sections
        model.add(.vpn)
        if isProvider {
            model.add(.authentication)
        }
        model.add(.configuration)
        if isProvider {
            model.add(.providerInfrastructure)
        }
        if isActiveProfile {
            if isProvider {
                model.add(.vpnResolvesHostname)
            }
            model.add(.vpnSurvivesSleep)
            model.add(.trusted)
            model.add(.trustedPolicy)
            model.add(.diagnostics)
            model.add(.feedback)
        }

        // headers
        model.setHeader(L10n.App.Service.Sections.Vpn.header, forSection: .vpn)
        if isProvider {
            model.setHeader(L10n.App.Service.Sections.Configuration.header, forSection: .authentication)
        } else {
            model.setHeader(L10n.App.Service.Sections.Configuration.header, forSection: .configuration)
        }
        if isActiveProfile {
            if isProvider {
                model.setHeader("", forSection: .vpnResolvesHostname)
                model.setHeader("", forSection: .vpnSurvivesSleep)
            }
            model.setHeader(L10n.Core.Service.Sections.Trusted.header, forSection: .trusted)
            model.setHeader(L10n.Core.Service.Sections.Diagnostics.header, forSection: .diagnostics)
            model.setHeader(L10n.Core.Organizer.Sections.Feedback.header, forSection: .feedback)
        }
        
        // footers
        if isActiveProfile {
            model.setFooter(L10n.Core.Service.Sections.Vpn.footer, forSection: .vpn)
            if isProvider {
                model.setFooter(L10n.Core.Service.Sections.VpnResolvesHostname.footer, forSection: .vpnResolvesHostname)
            }
            model.setFooter(L10n.Core.Service.Sections.VpnSurvivesSleep.footer, forSection: .vpnSurvivesSleep)
            model.setFooter(L10n.Core.Service.Sections.Trusted.footer, forSection: .trustedPolicy)
            model.setFooter(L10n.Core.Service.Sections.Diagnostics.footer, forSection: .diagnostics)
        }
        
        // rows
        if isActiveProfile {
            var rows: [RowType] = [.vpnService, .connectionStatus]
            if vpn.isEnabled {
                rows.append(.reconnect)
            }
            model.set(rows, forSection: .vpn)
        } else {
            model.set([.useProfile], forSection: .vpn)
        }
        if isProvider {
            model.set([.account], forSection: .authentication)
            model.set([.providerPool, .endpoint, .providerPreset, .networkSettings], forSection: .configuration)
            model.set([.providerRefresh], forSection: .providerInfrastructure)
        } else {
            model.set([.account, .endpoint, .hostParameters, .networkSettings], forSection: .configuration)
        }
        if isActiveProfile {
            if isProvider {
                model.set([.vpnResolvesHostname], forSection: .vpnResolvesHostname)
            }
            model.set([.vpnSurvivesSleep], forSection: .vpnSurvivesSleep)
            model.set([.trustedPolicy], forSection: .trustedPolicy)
            model.set([.dataCount, .serverConfiguration, .serverNetwork, .debugLog, .masksPrivateData], forSection: .diagnostics)

            var feedbackRows: [RowType] = [.faq]
            if ProductManager.shared.isEligibleForFeedback() {
                feedbackRows.append(.reportIssue)
            }
            model.set(feedbackRows, forSection: .feedback)
        }

        trustedNetworks.delegate = self
        trustedNetworks.load(from: uncheckedProfile.trustedNetworks)
        model.set(trustedNetworks.rows.map { mappedTrustedNetworksRow($0) }, forSection: .trusted)
    }

    private func reloadVpnStatus() {
        guard let profile = profile else {
            return
        }
        guard service.isActiveProfile(profile) else {
            return
        }
        var ips: [IndexPath] = []
        guard let statusIndexPath = statusIndexPath else {
            return
        }
        ips.append(statusIndexPath)
        if let dataCountIndexPath = dataCountIndexPath {
            currentDataCount = service.vpnDataCount
            ips.append(dataCountIndexPath)
        }
        tableView.reloadRows(at: ips, with: .none)
    }
    
    private func refreshDataCount(_ dataCount: (Int, Int)?) {
        currentDataCount = dataCount
        guard let dataCountIndexPath = dataCountIndexPath else {
            return
        }
        tableView.reloadRows(at: [dataCountIndexPath], with: .none)
    }
    
    func reloadSelectedRow(andRowsAt indexPaths: [IndexPath]? = nil) {
        guard let selectedIP = tableView.indexPathForSelectedRow else {
            return
        }
        var outdatedIPs = [selectedIP]
        if let otherIPs = indexPaths {
            outdatedIPs.append(contentsOf: otherIPs)
        }
        tableView.reloadRows(at: outdatedIPs, with: .none)
        tableView.selectRow(at: selectedIP, animated: false, scrollPosition: .none)
    }

    func clearSelection() {
        guard let selected = tableView.indexPathForSelectedRow else {
            return
        }
        tableView.deselectRow(at: selected, animated: true)
    }
}

// MARK: -

extension ServiceViewController: UITextFieldDelegate {
    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard string.rangeOfCharacter(from: CharacterSet.filename.inverted) == nil else {
            return false
        }
        if let text = textField.text {
            let replacement = (text as NSString).replacingCharacters(in: range, with: string)
            pendingRenameAction?.isEnabled = (replacement != uncheckedProfile.id)
        }
        return true
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        return true
    }
}

// MARK: -

extension ServiceViewController: TrustedNetworksUIDelegate {
    func trustedNetworksCouldDisconnect(_: TrustedNetworksUI) -> Bool {
        return (uncheckedProfile.trustedNetworks.policy == .disconnect) && (vpn.status != .disconnected)
    }
    
    func trustedNetworksShouldConfirmDisconnection(_: TrustedNetworksUI, triggeredAt rowIndex: Int, completionHandler: @escaping () -> Void) {
        confirmPotentialTrustedDisconnection(at: rowIndex, completionHandler: completionHandler)
    }
    
    func trustedNetworks(_: TrustedNetworksUI, shouldInsertWifiAt rowIndex: Int) {
        model.set(trustedNetworks.rows.map { mappedTrustedNetworksRow($0) }, forSection: .trusted)
        tableView.insertRows(at: [IndexPath(row: rowIndex, section: trustedSectionIndex)], with: .bottom)
    }
    
    func trustedNetworks(_: TrustedNetworksUI, shouldReloadWifiAt rowIndex: Int, isTrusted: Bool) {
        let genericCell = tableView.cellForRow(at: IndexPath(row: rowIndex, section: trustedSectionIndex))
        guard let cell = genericCell as? ToggleTableViewCell else {
            fatalError("Not a trusted Wi-Fi cell (\(type(of: genericCell)) != ToggleTableViewCell)")
        }
        guard isTrusted != cell.isOn else {
            return
        }
        cell.setOn(isTrusted, animated: true)
    }
    
    func trustedNetworks(_: TrustedNetworksUI, shouldDeleteWifiAt rowIndex: Int) {
        model.set(trustedNetworks.rows.map { mappedTrustedNetworksRow($0) }, forSection: .trusted)
        tableView.deleteRows(at: [IndexPath(row: rowIndex, section: trustedSectionIndex)], with: .top)
    }
    
    func trustedNetworksShouldReinstall(_: TrustedNetworksUI) {
        uncheckedProfile.trustedNetworks.includesMobile = trustedNetworks.trustsMobileNetwork
        uncheckedProfile.trustedNetworks.includedWiFis = trustedNetworks.trustedWifis
        if vpn.isEnabled {
            vpn.reinstall(completionHandler: nil)
        }
    }
}

// MARK: -

extension ServiceViewController: ConfigurationModificationDelegate {
    func configuration(didUpdate newConfiguration: OpenVPN.Configuration) {
        if let hostProfile = profile as? HostConnectionProfile {
            var builder = hostProfile.parameters.builder()
            builder.sessionConfiguration = newConfiguration
            hostProfile.parameters = builder.build()
        }
        reloadSelectedRow()
    }
    
    func configurationShouldReinstall() {
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: AccountViewControllerDelegate {
    func accountController(_ vc: AccountViewController, didEnterCredentials credentials: Credentials) {
    }
    
    func accountControllerDidComplete(_ accountVC: AccountViewController) {
        navigationController?.popViewController(animated: true)

        let credentials = accountVC.credentials
        guard credentials != service.credentials(for: uncheckedProfile) else {
            return
        }
        try? service.setCredentials(credentials, for: uncheckedProfile)
        reloadSelectedRow()
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: EndpointViewControllerDelegate {
    func endpointController(_: EndpointViewController, didUpdateWithNewAddress newAddress: String?, newProtocol: EndpointProtocol?) {
        if let providerProfile = profile as? ProviderConnectionProfile {
            providerProfile.manualAddress = newAddress
            providerProfile.manualProtocol = newProtocol
        }
        reloadSelectedRow()
    }
}

extension ServiceViewController: ProviderPoolViewControllerDelegate {
    func providerPoolController(_ vc: ProviderPoolViewController, didSelectPool pool: Pool) {
        navigationController?.popToViewController(self, animated: true)

        guard pool.id != uncheckedProviderProfile.poolId else {
            return
        }
        uncheckedProviderProfile.poolId = pool.id
        
        var extraReloadedRows = [endpointIndexPath]

        // fall back to a supported preset and reload preset row too
        let supportedPresets = pool.supportedPresetIds(in: uncheckedProviderProfile.infrastructure)
        if let presetId = uncheckedProviderProfile.preset?.id, !supportedPresets.contains(presetId),
            let fallback = supportedPresets.first {

            if fallback != uncheckedProviderProfile.presetId {
                extraReloadedRows.append(providerPresetIndexPath)
            }
            uncheckedProviderProfile.presetId = fallback
        }

        reloadSelectedRow(andRowsAt: extraReloadedRows)
        vpn.reinstallIfEnabled()

        if #available(iOS 12, *) {
            let title = service.screenTitle(forProviderName: uncheckedProviderProfile.name)
            IntentDispatcher.donateConnection(with: uncheckedProviderProfile, title: title)
        }
    }
    
    func providerPoolController(_: ProviderPoolViewController, didUpdateFavoriteGroups favoriteGroupIds: [String]) {
        uncheckedProviderProfile.favoriteGroupIds = favoriteGroupIds
    }
}

extension ServiceViewController: ProviderPresetViewControllerDelegate {
    func providerPresetController(_: ProviderPresetViewController, didSelectPreset preset: InfrastructurePreset) {
        navigationController?.popViewController(animated: true)
        
        guard preset.id != uncheckedProviderProfile.presetId else {
            return
        }
        uncheckedProviderProfile.presetId = preset.id
        reloadSelectedRow(andRowsAt: [endpointIndexPath])
        vpn.reinstallIfEnabled()
    }
}

extension ServiceViewController: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        guard isPendingTrustedWiFi else {
            return
        }
        isPendingTrustedWiFi = false
        trustCurrentWiFi()
    }
}

// MARK: -

private extension ServiceViewController {
    private var uncheckedProfile: ConnectionProfile {
        guard let profile = profile else {
            fatalError("Expected non-nil profile here")
        }
        return profile
    }

    private var uncheckedProviderProfile: ProviderConnectionProfile {
        guard let profile = profile as? ProviderConnectionProfile else {
            fatalError("Expected ProviderConnectionProfile (found: \(type(of: self.profile)))")
        }
        return profile
    }
    
    private var uncheckedHostProfile: HostConnectionProfile {
        guard let profile = profile as? HostConnectionProfile else {
            fatalError("Expected HostConnectionProfile (found: \(type(of: self.profile)))")
        }
        return profile
    }
}
