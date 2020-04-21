//
//  TransientStore.swift
//  Passepartout
//
//  Created by Davide De Rosa on 7/16/18.
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

import Foundation
import TunnelKit
import SwiftyBeaver

private let log = SwiftyBeaver.self

public class TransientStore {
    private struct Keys {
        static let didHandleSubreddit = "DidHandleSubreddit"
        
        static let masksPrivateData = "MasksPrivateData"

        // migrations
        
        static let didMigrateHostsRoutingPolicies = "DidMigrateHostsRoutingPolicies"
        
        static let didMigrateDynamicProviders = "DidMigrateDynamicProviders"

        static let didMigrateHostsToUUID = "DidMigrateHostsToUUID"
    }
    
    public static let shared = TransientStore()
    
    private static var serviceURL: URL {
        return GroupConstants.App.documentsURL.appendingPathComponent(AppConstants.Store.serviceFilename)
    }
    
    public let service: ConnectionService

    public static var didHandleSubreddit: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.didHandleSubreddit)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.didHandleSubreddit)
        }
    }

    public static var masksPrivateData: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.masksPrivateData)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.masksPrivateData)
        }
    }
    
    public static var didMigrateHostsRoutingPolicies: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.didMigrateHostsRoutingPolicies)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.didMigrateHostsRoutingPolicies)
        }
    }
    
    public static var didMigrateDynamicProviders: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.didMigrateDynamicProviders)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.didMigrateDynamicProviders)
        }
    }

    public static var didMigrateHostsToUUID: Bool {
        get {
            return UserDefaults.standard.bool(forKey: Keys.didMigrateHostsToUUID)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.didMigrateHostsToUUID)
        }
    }

    public static var baseVPNConfiguration: OpenVPNTunnelProvider.ConfigurationBuilder {
        let sessionBuilder = OpenVPN.ConfigurationBuilder()
        var builder = OpenVPNTunnelProvider.ConfigurationBuilder(sessionConfiguration: sessionBuilder.build())
        builder.mtu = 1250
        builder.shouldDebug = true
//        builder.debugLogFormat = "$Dyyyy-MM-dd HH:mm:ss.SSS$d $L $N.$F:$l - $M"
//        builder.debugLogFormat = "$DHH:mm:ss$d $N.$F:$l - $M"
        builder.debugLogFormat = AppConstants.Log.debugFormat
        builder.masksPrivateData = masksPrivateData
        return builder
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Keys.didHandleSubreddit: false,
            Keys.masksPrivateData: true
        ])
        
        TransientStore.migrateDocumentsToAppGroup()

        // this must be graceful
        ConnectionService.migrateJSON(from: TransientStore.serviceURL, to: TransientStore.serviceURL)
        
        let cfg = TransientStore.baseVPNConfiguration.build()
        do {
            var data = try Data(contentsOf: TransientStore.serviceURL)
            if let content = String(data: data, encoding: .utf8) {
                log.verbose("Service JSON:")
                log.verbose(content)
            }

            // pre-parsing migrations
            if let migratedData = TransientStore.migratedDataIfNecessary(fromData: data) {
                data = migratedData
            }
            
            service = try JSONDecoder().decode(ConnectionService.self, from: data)
            service.baseConfiguration = cfg

            // pre-load migrations
            if !TransientStore.didMigrateDynamicProviders {
                service.migrateProvidersToLowercase()
                TransientStore.didMigrateDynamicProviders = true
            }
            if !TransientStore.didMigrateHostsToUUID {
                service.migrateHostsToUUID()
                TransientStore.didMigrateHostsToUUID = true
            }

            service.loadProfiles()

            // post-load migrations
            if !TransientStore.didMigrateHostsRoutingPolicies {
                if service.reloadHostProfilesFromConfigurationFiles() {
                    service.saveProfiles()
                }
                TransientStore.didMigrateHostsRoutingPolicies = true
            }
        } catch let e {
            log.error("Could not decode service: \(e)")
            service = ConnectionService(
                withAppGroup: GroupConstants.App.groupId,
                baseConfiguration: cfg
            )
            
            // fresh install, skip all migrations
            TransientStore.didMigrateHostsRoutingPolicies = true
            TransientStore.didMigrateDynamicProviders = true
            TransientStore.didMigrateHostsToUUID = true

//            // hardcoded loading
//            _ = service.addProfile(ProviderConnectionProfile(name: .pia), credentials: nil)
//            _ = service.addProfile(HostConnectionProfile(title: "vps"), credentials: Credentials(username: "foo", password: "bar"))
//            service.activateProfile(service.profiles.first!)
        }
        service.observeVPNDataCount(milliseconds: GroupConstants.VPN.dataCountInterval)
    }
    
    public func serialize(withProfiles: Bool) {
        try? JSONEncoder().encode(service).write(to: TransientStore.serviceURL)
        if withProfiles {
            service.saveProfiles()
        }
    }
    
    //
    
    private static func migrateDocumentsToAppGroup() {
        var hasMigrated = false
        let oldDocumentsURL = FileManager.default.userURL(for: .documentDirectory, appending: nil)
        let newDocumentsURL = GroupConstants.App.documentsURL
        log.debug("App documentsURL: \(oldDocumentsURL)")
        log.debug("Group documentsURL: \(newDocumentsURL)")
        let fm = FileManager.default
        do {
            for c in try fm.contentsOfDirectory(atPath: oldDocumentsURL.path) {
                guard c != "Inbox" else {
                    continue
                }
                let old = oldDocumentsURL.appendingPathComponent(c)
                let new = newDocumentsURL.appendingPathComponent(c)
                log.verbose("Move:")
                log.verbose("\tFROM: \(old)")
                log.verbose("\tTO: \(new)")
                try fm.moveItem(at: old, to: new)
                hasMigrated = true
            }
        } catch let e {
            hasMigrated = false
            log.error("Could not migrate documents to App Group: \(e)")
        }
        if hasMigrated {
            log.debug("Documents migrated to App Group")
        }
    }

    private static func migratedDataIfNecessary(fromData data: Data) -> Data? {
        guard !TransientStore.didMigrateHostsToUUID else {
            return data
        }

        guard var json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }

        // do JSON migrations here
        migrateHostTitles(&json)

        guard let migratedData = try? JSONSerialization.data(withJSONObject: json, options: []) else {
            return nil
        }
        return migratedData
    }

    private static func migrateHostTitles(_ json: inout [String: Any]) {
        if json["hostTitles"] == nil {
            json["hostTitles"] = [:]
        }
    }
}
