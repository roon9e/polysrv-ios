# Anchored edits applied to the upstream Telegram-iOS tree by apply_polysrv.py.
#
# Each entry is a dict:
#   file    relative path of the upstream file to edit
#   old     the exact upstream text to find (must be present unless the edit is
#           already applied, i.e. `new` is already in the file)
#   new     the replacement text
#   label   short description used in the report
#   count   optional: number of occurrences to replace, or "all" (default 1)
#
# The overlay's PolySRV sources compile into TelegramCore, so the Swift edits
# below can reference PolySrvServers directly.

NETWORK_SWIFT = "submodules/TelegramCore/Sources/Network/Network.swift"
ACCOUNT_SWIFT = "submodules/TelegramCore/Sources/Account/Account.swift"
API_ENV_H = "submodules/MtProtoKit/PublicHeaders/MtProtoKit/MTApiEnvironment.h"
API_ENV_M = "submodules/MtProtoKit/Sources/MTApiEnvironment.m"
AUTH_SERVICE_M = "submodules/MtProtoKit/Sources/MTDatacenterAuthMessageService.m"
CONTEXT_M = "submodules/MtProtoKit/Sources/MTContext.m"
RUST_ENGINE_SWIFT = "submodules/MTProtoRustEngine/Sources/MTProtoRustEngine/RustNetworkEngine.swift"
AUTH_SEQUENCE_SWIFT = "submodules/AuthorizationUI/Sources/AuthorizationSequenceController.swift"
AUTH_PHONE_SWIFT = "submodules/AuthorizationUI/Sources/AuthorizationSequencePhoneEntryController.swift"
APP_DELEGATE_SWIFT = "submodules/TelegramUI/Sources/AppDelegate.swift"
SHARED_ACCOUNT_CONTEXT_SWIFT = "submodules/TelegramUI/Sources/SharedAccountContext.swift"
LOGOUT_OPTIONS_SWIFT = "submodules/SettingsUI/Sources/LogoutOptionsController.swift"
DELETE_ACCOUNT_OPTIONS_SWIFT = "submodules/SettingsUI/Sources/DeleteAccountOptionsController.swift"
SETTINGS_SEARCHABLE_ITEMS_SWIFT = "submodules/SettingsUI/Sources/Search/SettingsSearchableItems.swift"
SETTINGS_ACCOUNTS_ITEMS_SWIFT = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoSettingsItems.swift"
SETTINGS_ACCOUNTS_ACTIONS_SWIFT = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreenSettingsActions.swift"
PEERINFO_SCREEN_SWIFT = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoScreen.swift"
TELEGRAM_BUILD = "Telegram/BUILD"

EDITS = [
    # -- TelegramCore/Network.swift -------------------------------------------
    # 1. Publish the selected server into the api environment BEFORE the
    #    MTContext is created (the context copies the environment at init).
    {
        "file": NETWORK_SWIFT,
        "label": "Network.swift apiEnvironment server key and DC lock",
        "old": (
            "            apiEnvironment.accessHostOverride = networkSettings?.backupHostOverride\n"
        ),
        "new": (
            "            apiEnvironment.accessHostOverride = networkSettings?.backupHostOverride\n"
            "            \n"
            "            // PolySRV: force file logging so a connection problem can be read from the app's\n"
            "            // Documents; a release build otherwise keeps it off.\n"
            "            Logger.shared.logToFile = true\n"
            "            \n"
            "            // PolySRV: a non-Telegram account points every datacenter at its\n"
            "            // own server. The public key replaces the built-in one for non-CDN\n"
            "            // datacenters, and a single-machine server locks its endpoints so\n"
            "            // help.getConfig cannot rewrite them.\n"
            "            let polySrvServer = PolySrvServers.shared.server(forAccount: accountId)\n"
            "            // PolySRV: a server chosen before the account existed (the picker that\n"
            "            // precedes adding one) is bound to it on its first network, so the\n"
            "            // choice sticks to that account and the pending value is never handed\n"
            "            // to another account that has no binding of its own.\n"
            "            PolySrvServers.shared.bindPendingIfNeeded(forAccount: accountId)\n"
            "            if let polySrvServer = polySrvServer, !polySrvServer.isTelegram {\n"
            "                apiEnvironment.customServerPublicKey = polySrvServer.rsaPublicKey.isEmpty ? nil : polySrvServer.rsaPublicKey\n"
            "                apiEnvironment.datacenterOptionsLocked = !polySrvServer.multiDc\n"
            "                Logger.shared.log(\"PolySRV\", \"account \\(accountId.int64): server=\\(polySrvServer.id) dc=\\(polySrvServer.mainDcId) endpoint=\\(polySrvServer.endpoint) keyLen=\\(polySrvServer.rsaPublicKey.count) locked=\\(!polySrvServer.multiDc)\")\n"
            "            }\n"
            "            \n"
            "            // PolySRV: when an account's network is built for a different server\n"
            "            // (host:port), the previous server's persisted datacenter keys, addresses\n"
            "            // and tokens must be dropped before the context loads them: otherwise the\n"
            "            // handshake presents the old server's permanent key and the new server\n"
            "            // answers -404 without ever replacing it. This is the reset desktop's\n"
            "            // restoreServer performs for a server switch.\n"
            "            let polySrvScope = PolySrvServers.scope(for: polySrvServer)\n"
            "            if PolySrvServers.shared.appliedScope(forAccount: accountId) != polySrvScope {\n"
            "                apiEnvironment.datacenterStateReset = true\n"
            "                PolySrvServers.shared.setAppliedScope(polySrvScope, forAccount: accountId)\n"
            "                Logger.shared.log(\"PolySRV\", \"reset datacenter state for scope \\(polySrvScope)\")\n"
            "            }\n"
        ),
    },
    # 2. Seed the datacenters from the server when one is selected; otherwise
    #    keep upstream's official seed list untouched.
    {
        "file": NETWORK_SWIFT,
        "label": "Network.swift server seed addresses",
        "old": (
            "            for (id, ips) in seedAddressList {\n"
            "                context.setSeedAddressSetForDatacenterWithId(id, seedAddressSet: MTDatacenterAddressSet(addressList: ips.map { MTDatacenterAddress(ip: $0, port: 443, preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false, secret: nil) }))\n"
            "            }\n"
        ),
        "new": (
            "            if let polySrvServer = polySrvServer, !polySrvServer.isTelegram {\n"
            "                // Desktop parity: a server with no explicit DC table maps its one\n"
            "                // machine onto datacenters 1...5 so media and migration keep working.\n"
            "                let polySrvDcIds: [Int] = polySrvServer.dataCenters.isEmpty ? [1, 2, 3, 4, 5] : polySrvServer.dataCenters.map { $0.id }\n"
            "                for dcId in polySrvDcIds {\n"
            "                    context.setSeedAddressSetForDatacenterWithId(dcId, seedAddressSet: MTDatacenterAddressSet(addressList: [MTDatacenterAddress(ip: polySrvServer.host(forDataCenterId: dcId), port: UInt16(polySrvServer.port(forDataCenterId: dcId)), preferForMedia: false, restrictToTcp: polySrvServer.restrictToTcp, cdn: false, preferForProxy: false, secret: nil)]))\n"
            "                }\n"
            "            } else {\n"
            "                for (id, ips) in seedAddressList {\n"
            "                    context.setSeedAddressSetForDatacenterWithId(id, seedAddressSet: MTDatacenterAddressSet(addressList: ips.map { MTDatacenterAddress(ip: $0, port: 443, preferForMedia: false, restrictToTcp: false, cdn: false, preferForProxy: false, secret: nil) }))\n"
            "                }\n"
            "            }\n"
        ),
    },
    # PolySRV: a self-hosted server may not implement temporary (PFS) keys. With
    # them on, the main session asks for an ephemeral key it can never bind and
    # never sends the login request. Use the permanent key for a custom server.
    {
        "file": NETWORK_SWIFT,
        "label": "Network.swift no temp keys for a custom server",
        "old": (
            "            let useTempAuthKeys: Bool = true\n"
        ),
        "new": (
            "            // PolySRV: a self-hosted server may not implement temporary (PFS) keys, and\n"
            "            // with them on the main session waits for an ephemeral key it can never bind.\n"
            "            let useTempAuthKeys: Bool = (polySrvServer?.isTelegram ?? true)\n"
        ),
    },
    {
        "file": NETWORK_SWIFT,
        "label": "Network.swift no temp key refresh for a custom server",
        "old": (
            "            context.refreshesTemporaryKeys = !supplementary\n"
        ),
        "new": (
            "            context.refreshesTemporaryKeys = !supplementary && useTempAuthKeys\n"
        ),
    },
    # PolySRV: use Network.framework for TCP. The bundled GCDAsyncSocket transport is
    # what the client used by default, and it is the one path that does not connect
    # where the picker's own NWConnection does; the network then uses the same
    # transport as the picker. The WEB-proxy override below still wins.
    {
        "file": NETWORK_SWIFT,
        "label": "Network.swift use Network.framework for TCP",
        "old": (
            "            let baseTcpConnectionInterfaceFactory = context.makeTcpConnectionInterface\n"
        ),
        "new": (
            "            if #available(iOS 12.0, macOS 14.0, *) {\n"
            "                context.makeTcpConnectionInterface = { delegate, delegateQueue in\n"
            "                    return NetworkFrameworkTcpConnectionInterface(delegate: delegate, delegateQueue: delegateQueue)\n"
            "                }\n"
            "            }\n"
            "            let baseTcpConnectionInterfaceFactory = context.makeTcpConnectionInterface\n"
        ),
    },
    # -- TelegramCore/Account.swift -------------------------------------------
    # A fresh account starts on the selected server's main datacenter.
    {
        "file": ACCOUNT_SWIFT,
        "label": "Account.swift initialDatacenterId from server",
        "old": (
            "                        #if DEBUG\n"
            "                        let initialDatacenterId: Int = 1\n"
            "                        #else\n"
            "                        let initialDatacenterId: Int = 2\n"
            "                        #endif\n"
        ),
        "new": (
            "                        #if DEBUG\n"
            "                        let defaultInitialDatacenterId: Int = 1\n"
            "                        #else\n"
            "                        let defaultInitialDatacenterId: Int = 2\n"
            "                        #endif\n"
            "                        let initialDatacenterId: Int = PolySrvServers.shared.server(forAccount: id).flatMap { $0.isTelegram ? nil : $0.mainDcId } ?? defaultInitialDatacenterId\n"
        ),
    },
    # Switching the server of a live (unauthorized) account: bind the choice and
    # rebuild the network so the new seeds, key and lock take effect. Same-shape
    # rebuild as changedMasterDatacenterId, without its equal-dc early return,
    # inserted here so it can use this file's members.
    {
        "file": ACCOUNT_SWIFT,
        "label": "Account.swift polySrvApplyServer rebuild",
        "old": (
            "    public func changedMasterDatacenterId(accountManager: AccountManager<TelegramAccountManagerTypes>, masterDatacenterId: Int32) -> Signal<UnauthorizedAccount, NoError> {\n"
        ),
        "new": (
            "    public func polySrvApplyServer(accountManager: AccountManager<TelegramAccountManagerTypes>, serverId: String) -> Signal<UnauthorizedAccount, NoError> {\n"
            "        PolySrvServers.shared.setServer(id: serverId, forAccount: self.id)\n"
            "        Logger.shared.log(\"PolySRV\", \"apply server \\(serverId) for account \\(self.id.int64)\")\n"
            "        \n"
            "        let keychain = makeExclusiveKeychain(id: self.id, postbox: self.postbox)\n"
            "        return accountManager.transaction { transaction -> (LocalizationSettings?, ProxySettings?, NetworkEngineInputs) in\n"
            "            return (transaction.getSharedData(SharedDataKeys.localizationSettings)?.get(LocalizationSettings.self), transaction.getSharedData(SharedDataKeys.proxySettings)?.get(ProxySettings.self), networkEngineInputs(transaction: transaction))\n"
            "        }\n"
            "        |> mapToSignal { localizationSettings, proxySettings, networkEngine -> Signal<(LocalizationSettings?, ProxySettings?, NetworkSettings?, AppConfiguration, NetworkEngineInputs), NoError> in\n"
            "            return self.postbox.transaction { transaction -> (LocalizationSettings?, ProxySettings?, NetworkSettings?, AppConfiguration, NetworkEngineInputs) in\n"
            "                return (localizationSettings, proxySettings, transaction.getPreferencesEntry(key: PreferencesKeys.networkSettings)?.get(NetworkSettings.self), transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration)?.get(AppConfiguration.self) ?? .defaultValue, networkEngine)\n"
            "            }\n"
            "        }\n"
            "        |> mapToSignal { localizationSettings, proxySettings, networkSettings, appConfiguration, networkEngine -> Signal<UnauthorizedAccount, NoError> in\n"
            "            #if DEBUG\n"
            "            let defaultDatacenterId: Int = 1\n"
            "            #else\n"
            "            let defaultDatacenterId: Int = 2\n"
            "            #endif\n"
            "            let datacenterId = PolySrvServers.shared.server(forAccount: self.id)?.mainDcId ?? defaultDatacenterId\n"
            "            return initializedNetwork(accountId: self.id, arguments: self.networkArguments, supplementary: false, datacenterId: datacenterId, keychain: keychain, basePath: self.basePath, testingEnvironment: self.testingEnvironment, languageCode: localizationSettings?.primaryComponent.languageCode, proxySettings: proxySettings, networkSettings: networkSettings, networkEngine: networkEngine, phoneNumber: nil, useRequestTimeoutTimers: false, appConfiguration: appConfiguration)\n"
            "            |> map { network in\n"
            "                let updated = UnauthorizedAccount(accountManager: accountManager, networkArguments: self.networkArguments, id: self.id, rootPath: self.rootPath, basePath: self.basePath, testingEnvironment: self.testingEnvironment, postbox: self.postbox, network: network)\n"
            "                updated.shouldBeServiceTaskMaster.set(self.shouldBeServiceTaskMaster.get())\n"
            "                return updated\n"
            "            }\n"
            "        }\n"
            "    }\n"
            "    \n"
            "    public func changedMasterDatacenterId(accountManager: AccountManager<TelegramAccountManagerTypes>, masterDatacenterId: Int32) -> Signal<UnauthorizedAccount, NoError> {\n"
        ),
    },
    # -- MtProtoKit ------------------------------------------------------------
    {
        "file": API_ENV_H,
        "label": "MTApiEnvironment.h server key and DC lock fields",
        "old": (
            "@property (nonatomic) NSDictionary * _Nullable datacenterAddressOverrides;\n"
            "@property (nonatomic) NSString * _Nullable accessHostOverride;\n"
        ),
        "new": (
            "@property (nonatomic) NSDictionary * _Nullable datacenterAddressOverrides;\n"
            "@property (nonatomic) NSString * _Nullable accessHostOverride;\n"
            "\n"
            "// PolySRV: a self-hosted server's RSA public key (PEM) replaces the built-in\n"
            "// one for non-CDN datacenters, and datacenterOptionsLocked stops a fixed\n"
            "// server's endpoints from being rewritten by help.getConfig.\n"
            "@property (nonatomic) NSString * _Nullable customServerPublicKey;\n"
            "@property (nonatomic) bool datacenterOptionsLocked;\n"
            "\n"
            "// PolySRV: the network is being built for a different server (host:port), so\n"
            "// the persisted datacenter keys, addresses and tokens of the previous server\n"
            "// must not be reloaded. Consumed once by MTContext when its keychain is set.\n"
            "@property (nonatomic) bool datacenterStateReset;\n"
        ),
    },
    {
        "file": API_ENV_M,
        "label": "MTApiEnvironment.m carry server key and DC lock through withUpdated*",
        "count": "all",
        "old": (
            "    result.accessHostOverride = self.accessHostOverride;\n"
        ),
        "new": (
            "    result.accessHostOverride = self.accessHostOverride;\n"
            "    result.customServerPublicKey = self.customServerPublicKey;\n"
            "    result.datacenterOptionsLocked = self.datacenterOptionsLocked;\n"
            "    result.datacenterStateReset = self.datacenterStateReset;\n"
        ),
    },
    {
        "file": AUTH_SERVICE_M,
        "label": "MTDatacenterAuthMessageService.m import MTApiEnvironment",
        "old": (
            "#import <MtProtoKit/MTContext.h>\n"
        ),
        "new": (
            "#import <MtProtoKit/MTContext.h>\n"
            "#import <MtProtoKit/MTApiEnvironment.h>\n"
        ),
    },
    {
        "file": AUTH_SERVICE_M,
        "label": "MTDatacenterAuthMessageService.m custom server public key",
        "old": (
            "    } else {\n"
            "        _publicKeys = defaultPublicKeys(!mtProto.context.isTestingEnvironment);\n"
            "        _stage = MTDatacenterAuthStagePQ;\n"
            "    }\n"
        ),
        "new": (
            "    } else {\n"
            "        NSString *customKey = mtProto.context.apiEnvironment.customServerPublicKey;\n"
            "        if (customKey.length != 0) {\n"
            "            _publicKeys = @[[[MTDatacenterAuthPublicKey alloc] initWithPublicKey:customKey]];\n"
            "        } else {\n"
            "            _publicKeys = defaultPublicKeys(!mtProto.context.isTestingEnvironment);\n"
            "        }\n"
            "        _stage = MTDatacenterAuthStagePQ;\n"
            "    }\n"
        ),
    },
    # PolySRV: a network built for a different server (host:port) must not reload
    # the previous server's datacenter state, or its handshake presents the old
    # server's permanent key and the new server answers -404 forever with no path
    # that replaces it (the logout probe is disabled for a locked server).
    {
        "file": CONTEXT_M,
        "label": "MTContext.m reset datacenter state on a server switch",
        "old": (
            "        _keychain = keychain;\n"
            "        \n"
            "        if (_keychain != nil)\n"
            "        {\n"
        ),
        "new": (
            "        _keychain = keychain;\n"
            "        \n"
            "        if (_keychain != nil)\n"
            "        {\n"
            "            if (_apiEnvironment.datacenterStateReset) {\n"
            "                // PolySRV: this account's network is being built for another\n"
            "                // server (host:port). Drop the previous server's datacenter\n"
            "                // keys, addresses, selected schemes, tokens and scheme stats so\n"
            "                // the loads below start empty and the new seeds, RSA key and\n"
            "                // lock take over. This is desktop's restoreServer reset.\n"
            "                [keychain removeObjectForKey:@\"datacenterAuthInfoById\" group:@\"persistent\"];\n"
            "                [keychain removeObjectForKey:@\"datacenterAddressSetById\" group:@\"persistent\"];\n"
            "                [keychain removeObjectForKey:@\"datacenterManuallySelectedSchemeById_v1\" group:@\"persistent\"];\n"
            "                [keychain removeObjectForKey:@\"authTokenById\" group:@\"persistent\"];\n"
            "                [keychain removeObjectForKey:@\"transportSchemeStats_v1\" group:@\"temp\"];\n"
            "                if (MTLogEnabled()) {\n"
            "                    MTLog(@\"[MTContext#%\" PRIxPTR \": datacenter state reset for the new server]\", (intptr_t)self);\n"
            "                }\n"
            "            }\n"
        ),
    },
    {
        "file": CONTEXT_M,
        "label": "MTContext.m lock config-driven address updates",
        "old": (
            "        if (addressSet != nil && datacenterId != 0)\n"
            "        {\n"
            "            if (MTLogEnabled()) {\n"
            "                MTLog(@\"[MTContext#%\" PRIxPTR \": address set updated for %d]\", (intptr_t)self, datacenterId);\n"
            "            }\n"
        ),
        "new": (
            "        if (_apiEnvironment.datacenterOptionsLocked) {\n"
            "            // PolySRV: a fixed single-machine server owns its endpoints; a\n"
            "            // server-pushed help.getConfig list must not replace them.\n"
            "            if (MTLogEnabled()) {\n"
            "                MTLog(@\"[MTContext#%\" PRIxPTR \": ignoring address set for %d (datacenter options locked)]\", (intptr_t)self, datacenterId);\n"
            "            }\n"
            "            return;\n"
            "        }\n"
            "        if (addressSet != nil && datacenterId != 0)\n"
            "        {\n"
            "            if (MTLogEnabled()) {\n"
            "                MTLog(@\"[MTContext#%\" PRIxPTR \": address set updated for %d]\", (intptr_t)self, datacenterId);\n"
            "            }\n"
        ),
    },
    {
        "file": CONTEXT_M,
        "label": "MTContext.m lock added addresses",
        "old": (
            "    if (address == nil || datacenterId == 0)\n"
            "        return;\n"
            "    \n"
            "    [[MTContext contextQueue] dispatchOnQueue:^\n"
            "    {\n"
            "        bool updated = false;\n"
        ),
        "new": (
            "    if (address == nil || datacenterId == 0)\n"
            "        return;\n"
            "    if (_apiEnvironment.datacenterOptionsLocked)\n"
            "        return;\n"
            "    \n"
            "    [[MTContext contextQueue] dispatchOnQueue:^\n"
            "    {\n"
            "        bool updated = false;\n"
        ),
    },
    {
        "file": CONTEXT_M,
        "label": "MTContext.m prefer seed addresses when locked",
        "old": (
            "        MTDatacenterAddressSet *addressSet = _datacenterAddressSetById[@(datacenterId)];\n"
            "        if (addressSet != nil && addressSet.addressList.count != 0) {\n"
            "            result = _datacenterAddressSetById[@(datacenterId)];\n"
            "        } else {\n"
            "            result = _datacenterSeedAddressSetById[@(datacenterId)];\n"
            "        }\n"
        ),
        "new": (
            "        MTDatacenterAddressSet *addressSet = _datacenterAddressSetById[@(datacenterId)];\n"
            "        if (_apiEnvironment.datacenterOptionsLocked) {\n"
            "            // PolySRV: prefer the seeded (server) addresses over anything\n"
            "            // loaded from the keychain for a locked, fixed server.\n"
            "            MTDatacenterAddressSet *seedAddressSet = _datacenterSeedAddressSetById[@(datacenterId)];\n"
            "            if (seedAddressSet != nil && seedAddressSet.addressList.count != 0) {\n"
            "                result = seedAddressSet;\n"
            "                return;\n"
            "            }\n"
            "        }\n"
            "        if (addressSet != nil && addressSet.addressList.count != 0) {\n"
            "            result = _datacenterAddressSetById[@(datacenterId)];\n"
            "        } else {\n"
            "            result = _datacenterSeedAddressSetById[@(datacenterId)];\n"
            "        }\n"
        ),
    },
    # -- Rust MTProto engine ---------------------------------------------------
    {
        "file": RUST_ENGINE_SWIFT,
        "label": "RustNetworkEngine.swift custom server public key",
        "old": (
            "        guard let runtime = RustEngineRuntime.shared else {\n"
            "            rustEngineImportantLog(\"[MTProtoRust] declined: engine is unavailable\")\n"
            "            return nil\n"
            "        }\n"
            "        return RustNetworkEngine(runtime: runtime, context: context)\n"
        ),
        "new": (
            "        guard let runtime = RustEngineRuntime.shared else {\n"
            "            rustEngineImportantLog(\"[MTProtoRust] declined: engine is unavailable\")\n"
            "            return nil\n"
            "        }\n"
            "        if let customKey = apiEnvironment.customServerPublicKey, !customKey.isEmpty {\n"
            "            return RustNetworkEngine(runtime: runtime, context: context, serverPublicKeys: [customKey])\n"
            "        }\n"
            "        return RustNetworkEngine(runtime: runtime, context: context)\n"
        ),
    },
    # -- AuthorizationUI: the pre-login server picker --------------------------
    # The splash's "Start Messaging" first offers the server list on a first run,
    # then proceeds to phone entry. Choosing a server binds the account and
    # rebuilds its network before any login is attempted.
    {
        "file": AUTH_SEQUENCE_SWIFT,
        "label": "AuthorizationSequenceController.swift show server picker",
        "old": (
            "            controller.nextPressed = { [weak self] strings in\n"
            "                if let strongSelf = self {\n"
            "                    if let strings = strings {\n"
            "                        strongSelf.presentationData = strongSelf.presentationData.withStrings(strings)\n"
            "                    }\n"
            "                    let masterDatacenterId = strongSelf.account.masterDatacenterId\n"
            "                    let isTestingEnvironment = strongSelf.account.testingEnvironment\n"
            "                    \n"
            "                    let countryCode = AuthorizationSequenceCountrySelectionController.defaultCountryCode()\n"
            "                    \n"
            "                    let _ = strongSelf.engine.auth.setState(state: UnauthorizedAccountState(isTestingEnvironment: isTestingEnvironment, masterDatacenterId: masterDatacenterId, contents: .phoneEntry(countryCode: countryCode, number: \"\"))).startStandalone()\n"
            "                }\n"
            "            }\n"
        ),
        "new": (
            "            controller.nextPressed = { [weak self] strings in\n"
            "                if let strongSelf = self {\n"
            "                    if let strings = strings {\n"
            "                        strongSelf.presentationData = strongSelf.presentationData.withStrings(strings)\n"
            "                    }\n"
            "                    strongSelf.polySrvProceedToLogin()\n"
            "                }\n"
            "            }\n"
        ),
    },
    {
        "file": AUTH_SEQUENCE_SWIFT,
        "label": "AuthorizationSequenceController.swift picker helpers",
        "old": (
            "    private func phoneEntryController(countryCode: Int32, number: String, splashController: AuthorizationSequenceSplashController?) -> AuthorizationSequencePhoneEntryController {\n"
        ),
        "new": (
            "    private func polySrvProceedToLogin() {\n"
            "        let servers = PolySrvServers.shared.allServers()\n"
            "        // The picker cannot log an account out or ask a question by itself;\n"
            "        // deleting a server has to log out the accounts bound to it.\n"
            "        let environment = PolySrvServerPickerEnvironment(confirmDeletion: { [weak self] text, action in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            // The auth controller is a NavigationController, not a ViewController, so it\n"
            "            // has no present(_:in:) - present through its own overlay, the way the picker\n"
            "            // itself is shown, so the alert lands above it.\n"
            "            strongSelf.presentOverlay(controller: textAlertController(sharedContext: strongSelf.sharedContext, title: nil, text: text, actions: [TextAlertAction(type: .genericAction, title: \"Delete\", action: action), TextAlertAction(type: .defaultAction, title: \"Cancel\", action: {})]), inGlobal: true, blockInteraction: true)\n"
            "        }, logOut: { [weak self] accountId in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            let _ = logoutFromAccount(id: accountId, accountManager: strongSelf.sharedContext.accountManager, alreadyLoggedOutRemotely: false).startStandalone()\n"
            "        }, presentEditor: { [weak self] server, completion in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            strongSelf.polySrvPresentEditor(server: server, completion: completion)\n"
            "        })\n"
            "        let picker = PolySrvServerSelectController(servers: servers, account: self.account, theme: self.presentationData.theme, leftButtonTitle: \"Back\", environment: environment, onSelect: { [weak self] server in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            strongSelf.polySrvApplyAndContinue(serverId: server.id)\n"
            "        }, onCancel: { [weak self] in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            strongSelf.polySrvShowSplash()\n"
            "        })\n"
            "        self.presentOverlay(controller: picker, inGlobal: true, blockInteraction: true)\n"
            "    }\n"
            "    \n"
            "    // The add/edit form is a window presentation (the way the app shows its\n"
            "    // own input screens), so it gets a keyboard; the picker stepped aside and\n"
            "    // is put back when the form closes.\n"
            "    private func polySrvPresentEditor(server: PolySrvServer?, completion: @escaping (PolySrvServer?) -> Void) {\n"
            "        let controller = PolySrvServerEditController(server: server, theme: self.presentationData.theme, completion: { [weak self] saved in\n"
            "            completion(saved)\n"
            "            self?.polySrvProceedToLogin()\n"
            "        })\n"
            "        self.currentWindow?.present(controller, on: .root, blockInteraction: false, completion: {})\n"
            "    }\n"
            "    \n"
            "    private func polySrvApplyAndContinue(serverId: String) {\n"
            "        let _ = (self.account.polySrvApplyServer(accountManager: self.sharedContext.accountManager, serverId: serverId)\n"
            "        |> deliverOnMainQueue).startStrict(next: { [weak self] updated in\n"
            "            guard let strongSelf = self else {\n"
            "                return\n"
            "            }\n"
            "            strongSelf.account = updated\n"
            "            strongSelf.inAppPurchaseManager = InAppPurchaseManager(engine: .unauthorized(strongSelf.engine))\n"
            "            strongSelf.polySrvSetPhoneEntryState()\n"
            "        })\n"
            "    }\n"
            "    \n"
            "    private func polySrvSetPhoneEntryState() {\n"
            "        let masterDatacenterId = self.account.masterDatacenterId\n"
            "        let isTestingEnvironment = self.account.testingEnvironment\n"
            "        let countryCode = AuthorizationSequenceCountrySelectionController.defaultCountryCode()\n"
            "        let _ = self.engine.auth.setState(state: UnauthorizedAccountState(isTestingEnvironment: isTestingEnvironment, masterDatacenterId: masterDatacenterId, contents: .phoneEntry(countryCode: countryCode, number: \"\"))).startStandalone()\n"
            "    }\n"
            "    \n"
            "    private func polySrvShowSplash() {\n"
            "        let masterDatacenterId = self.account.masterDatacenterId\n"
            "        let isTestingEnvironment = self.account.testingEnvironment\n"
            "        let _ = self.engine.auth.setState(state: UnauthorizedAccountState(isTestingEnvironment: isTestingEnvironment, masterDatacenterId: masterDatacenterId, contents: .empty)).startStandalone()\n"
            "    }\n"
            "    \n"
            "    private func phoneEntryController(countryCode: Int32, number: String, splashController: AuthorizationSequenceSplashController?) -> AuthorizationSequencePhoneEntryController {\n"
        ),
    },
    # PolySRV: keep the splash behind the phone entry so its navigation bar has a
    # back button (the phone entry's backPressed returns to the splash). Without
    # this a first-run user has no way back to reopen the picker and change servers.
    {
        "file": AUTH_SEQUENCE_SWIFT,
        "label": "AuthorizationSequenceController.swift splash behind phone entry",
        "old": (
            "                case let .phoneEntry(countryCode, number):\n"
            "                    var controllers: [ViewController] = []\n"
            "                    if !self.otherAccountPhoneNumbers.1.isEmpty {\n"
            "                        controllers.append(self.splashController())\n"
            "                    }\n"
            "                    var previousSplashController: AuthorizationSequenceSplashController?\n"
        ),
        "new": (
            "                case let .phoneEntry(countryCode, number):\n"
            "                    var controllers: [ViewController] = []\n"
            "                    controllers.append(self.splashController())\n"
            "                    var previousSplashController: AuthorizationSequenceSplashController?\n"
        ),
    },
    # PolySRV: MTProto's logout check binds a temporary key to probe the permanent
    # one. A self-hosted server that rejects that bind (it may not implement temp
    # keys) is read as "the permanent key is gone", resetting the key in a loop —
    # which is what the server logged as ENCRYPTED_MESSAGE_INVALID on the bind.
    {
        "file": CONTEXT_M,
        "label": "MTContext.m skip the temp-key logout probe for a locked server",
        "old": (
            "- (void)checkIfLoggedOut:(NSInteger)datacenterId {\n"
            "    [[MTContext contextQueue] dispatchOnQueue:^{\n"
            "        MTDatacenterAuthInfo *authInfo = [self authInfoForDatacenterWithId:datacenterId selector:MTDatacenterAuthInfoSelectorPersistent];\n"
        ),
        "new": (
            "- (void)checkIfLoggedOut:(NSInteger)datacenterId {\n"
            "    if (_apiEnvironment.datacenterOptionsLocked) {\n"
            "        // PolySRV: a self-hosted server may not support the temporary-key bind this\n"
            "        // check makes, and a rejected bind would be read as the permanent key being\n"
            "        // gone, resetting it in a loop. Skip the probe for a fixed server.\n"
            "        return;\n"
            "    }\n"
            "    [[MTContext contextQueue] dispatchOnQueue:^{\n"
            "        MTDatacenterAuthInfo *authInfo = [self authInfoForDatacenterWithId:datacenterId selector:MTDatacenterAuthInfoSelectorPersistent];\n"
        ),
    },
    # PolySRV: the phone entry's back button returns to the server picker (so a
    # different server can be chosen), not to the splash.
    {
        "file": AUTH_SEQUENCE_SWIFT,
        "label": "AuthorizationSequenceController.swift phone entry back returns to the picker",
        "old": (
            "                if !strongSelf.otherAccountPhoneNumbers.1.isEmpty {\n"
            "                    let _ = (strongSelf.sharedContext.accountManager.transaction { transaction -> Void in\n"
            "                        transaction.removeAuth()\n"
            "                    }).startStandalone()\n"
            "                } else {\n"
            "                    let _ = strongSelf.engine.auth.setState(state: UnauthorizedAccountState(isTestingEnvironment: strongSelf.account.testingEnvironment, masterDatacenterId: strongSelf.account.masterDatacenterId, contents: .empty)).startStandalone()\n"
            "                }\n"
        ),
        "new": (
            "                if !strongSelf.otherAccountPhoneNumbers.1.isEmpty {\n"
            "                    let _ = (strongSelf.sharedContext.accountManager.transaction { transaction -> Void in\n"
            "                        transaction.removeAuth()\n"
            "                    }).startStandalone()\n"
            "                } else {\n"
            "                    strongSelf.polySrvProceedToLogin()\n"
            "                }\n"
        ),
    },
    # PolySRV: a phone number is "already authorized" only on the server it is
    # already on. Upstream compares the number against every other account, so
    # the same number could never be signed in to the official cloud and a
    # self-hosted server at once. The target server of the number being entered
    # is the account's own binding (set before phone entry), and the other
    # accounts are compared by their bound scope.
    {
        "file": AUTH_PHONE_SWIFT,
        "label": "AuthorizationSequencePhoneEntryController.swift already-authorized is per server",
        "old": (
            "            let logInNumber = cleanPhoneNumber(self.controllerNode.currentNumber, removePlus: true)\n"
            "            var existing: (String, AccountRecordId)?\n"
            "            for (number, id, isTestingEnvironment) in self.otherAccountPhoneNumbers.1 {\n"
            "                if isTestingEnvironment == self.isTestingEnvironment && cleanPhoneNumber(number, removePlus: true) == logInNumber {\n"
            "                    existing = (number, id)\n"
            "                }\n"
            "            }\n"
        ),
        "new": (
            "            let logInNumber = cleanPhoneNumber(self.controllerNode.currentNumber, removePlus: true)\n"
            "            // PolySRV: a number is only 'already authorized' on the server it\n"
            "            // is already on. The same number on another server (a custom one\n"
            "            // next to the official cloud) is a new account and goes through.\n"
            "            let polySrvTargetScope = PolySrvServers.scope(for: self.account.flatMap { PolySrvServers.shared.server(forAccount: $0.id) })\n"
            "            var existing: (String, AccountRecordId)?\n"
            "            for (number, id, isTestingEnvironment) in self.otherAccountPhoneNumbers.1 {\n"
            "                if isTestingEnvironment == self.isTestingEnvironment && cleanPhoneNumber(number, removePlus: true) == logInNumber && PolySrvServers.shared.boundScope(forAccount: id) == polySrvTargetScope {\n"
            "                    existing = (number, id)\n"
            "                }\n"
            "            }\n"
        ),
    },
    # PolySRV: put the app's logs in the app's own Documents so they can be pulled
    # off the device with file sharing, when there is no Mac to read the console.
    {
        "file": APP_DELEGATE_SWIFT,
        "label": "AppDelegate.swift log into Documents for retrieval",
        "old": (
            "        let logsPath = rootPath + \"/logs/app-logs\"\n"
            "        let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)\n"
            "        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: logsPath))\n"
        ),
        "new": (
            "        let logsPath = rootPath + \"/logs/app-logs\"\n"
            "        let _ = try? FileManager.default.createDirectory(atPath: logsPath, withIntermediateDirectories: true, attributes: nil)\n"
            "        var polySrvLogsPath = logsPath\n"
            "        if let polySrvDocuments = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {\n"
            "            let path = polySrvDocuments.path + \"/polysrv-logs\"\n"
            "            let _ = try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)\n"
            "            polySrvLogsPath = path\n"
            "        }\n"
            "        Logger.setSharedLogger(Logger(rootPath: rootPath, basePath: polySrvLogsPath))\n"
        ),
    },
    # PolySRV: expose the app's Documents so the log above is reachable from the
    # Files app / 3uTools on a device with no Mac.
    {
        "file": TELEGRAM_BUILD,
        "label": "Telegram/BUILD enable file sharing",
        "old": (
            "    <key>UIFileSharingEnabled</key>\n"
            "    <false/>\n"
        ),
        "new": (
            "    <key>UIFileSharingEnabled</key>\n"
            "    <true/>\n"
            "    <key>LSSupportsOpeningDocumentsInPlace</key>\n"
            "    <true/>\n"
        ),
    },
    # PolySRV: adding an account starts on the server picker, so the new account
    # is created already bound to the chosen server. Without this the auth
    # sequence sends an additional account straight to phone entry (its `.empty`
    # state, with otherAccountPhoneNumbers non-empty, skips the splash where the
    # picker lives) and the account silently lands on the official cloud.
    #
    # Only when a primary account already exists: the first run has no account
    # and nothing to present over, and its own auth sequence offers the picker
    # from the splash.
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift new-account server picker",
        "old": (
            "    public func beginNewAuth(testingEnvironment: Bool) {\n"
            "        let _ = self.accountManager.transaction({ transaction -> Void in\n"
            "            let _ = transaction.createAuth([.environment(AccountEnvironmentAttribute(environment: testingEnvironment ? .test : .production))])\n"
            "        }).start()\n"
            "    }\n"
        ),
        "new": (
            "    public func beginNewAuth(testingEnvironment: Bool) {\n"
            "        if let activeAccounts = self.activeAccountsValue, activeAccounts.primary != nil {\n"
            "            self.polySrvPickServerForNewAuth(testingEnvironment: testingEnvironment)\n"
            "            return\n"
            "        }\n"
            "        self.polySrvCreateAuth(testingEnvironment: testingEnvironment)\n"
            "    }\n"
            "    \n"
            "    // PolySRV: the pending selection this records is consumed by the new\n"
            "    // account's first network (PolySrvServers.bindPendingIfNeeded), so the\n"
            "    // account is born on the chosen server and never falls back to the\n"
            "    // official cloud silently.\n"
            "    private func polySrvPickServerForNewAuth(testingEnvironment: Bool) {\n"
            "        let theme = self.currentPresentationData.with { $0 }.theme\n"
            "        let environment = PolySrvServerPickerEnvironment(confirmDeletion: { [weak self] text, action in\n"
            "            guard let self = self else {\n"
            "                return\n"
            "            }\n"
            "            // Present through the root NavigationController's global overlay: the\n"
            "            // picker is shown there, and a plain present(in: .window(.root)) is a local\n"
            "            // overlay that Display renders below the global one, hidden behind it.\n"
            "            (self.mainWindow?.viewController as? NavigationController)?.presentOverlay(controller: textAlertController(sharedContext: self, title: nil, text: text, actions: [TextAlertAction(type: .genericAction, title: \"Delete\", action: action), TextAlertAction(type: .defaultAction, title: \"Cancel\", action: {})]), inGlobal: true, blockInteraction: true)\n"
            "        }, logOut: { [weak self] accountId in\n"
            "            guard let self = self else {\n"
            "                return\n"
            "            }\n"
            "            let _ = logoutFromAccount(id: accountId, accountManager: self.accountManager, alreadyLoggedOutRemotely: false).startStandalone()\n"
            "        }, presentEditor: { [weak self] server, completion in\n"
            "            guard let self = self else {\n"
            "                return\n"
            "            }\n"
            "            // Window presentation, like the app's own input screens, so the\n"
            "            // form gets a keyboard; the picker stepped aside first.\n"
            "            let editor = PolySrvServerEditController(server: server, theme: theme, completion: { [weak self] saved in\n"
            "                completion(saved)\n"
            "                self?.polySrvPickServerForNewAuth(testingEnvironment: testingEnvironment)\n"
            "            })\n"
            "            self.mainWindow?.present(editor, on: .root, blockInteraction: false, completion: {})\n"
            "        })\n"
            "        let picker = PolySrvServerSelectController(servers: PolySrvServers.shared.allServers(), account: nil, theme: theme, environment: environment, onSelect: { [weak self] server in\n"
            "            guard let self = self else {\n"
            "                return\n"
            "            }\n"
            "            Logger.shared.log(\"PolySRV\", \"new account on server \\(server.id) (\\(server.endpoint))\")\n"
            "            self.polySrvCreateAuth(testingEnvironment: testingEnvironment, serverId: server.id)\n"
            "        }, onCancel: {\n"
            "        })\n"
            "        (self.mainWindow?.viewController as? NavigationController)?.presentOverlay(controller: picker, inGlobal: true, blockInteraction: true)\n"
            "    }\n"
            "    \n"
            "    private func polySrvCreateAuth(testingEnvironment: Bool, serverId: String? = nil) {\n"
            "        let _ = self.accountManager.transaction({ transaction -> Void in\n"
            "            let polySrvAuthRecord = transaction.createAuth([.environment(AccountEnvironmentAttribute(environment: testingEnvironment ? .test : .production))])\n"
            "            // PolySRV: tie the choice to the account it was made for, so the\n"
            "            // selection is never handed to a different account (the official\n"
            "            // cloud's) that has no binding of its own.\n"
            "            if let serverId = serverId, let polySrvAuthRecord = polySrvAuthRecord {\n"
            "                PolySrvServers.shared.setPendingServer(id: serverId, forAccount: polySrvAuthRecord.id)\n"
            "            }\n"
            "        }).start()\n"
            "    }\n"
        ),
    },
    # PolySRV: a binding outlives the account it named, and a retained server (one
    # an account holds on to after the published list dropped it) is held by the
    # bindings. Prune both when the account set changes, so an unpublished server
    # really does vanish once no account is bound to it.
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift prune dead account bindings",
        "old": (
            "                    self.performAccountSettingsImportIfNecessary()\n"
            "                }\n"
        ),
        "new": (
            "                    self.performAccountSettingsImportIfNecessary()\n"
            "                    \n"
            "                    // PolySRV: drop the bindings of accounts that no longer exist,\n"
            "                    // so a server the published list no longer carries does not linger\n"
            "                    // just because a dead account still named it. The account that is\n"
            "                    // still authorizing is kept: it is not in `accounts` yet, and\n"
            "                    // pruning it would drop the binding its login is on.\n"
            "                    var polySrvKeeping = Set(self.activeAccountsValue!.accounts.map { $0.0 })\n"
            "                    if let polySrvAuthId = self.activeAccountsValue!.currentAuth?.id {\n"
            "                        polySrvKeeping.insert(polySrvAuthId)\n"
            "                    }\n"
            "                    PolySrvServers.shared.pruneAccounts(keeping: polySrvKeeping)\n"
            "                }\n"
        ),
    },
    # PolySRV: an account's identity is (user id, server), not the user id alone.
    # The same number on two servers is two accounts and both have to be kept;
    # this dedup is what collapses two records for one account, so the server
    # scope belongs in the key. Two records on the same server still collapse.
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift account identity includes the server",
        "old": (
            "                struct AccountPeerKey: Hashable {\n"
            "                    let peerId: EnginePeer.Id\n"
            "                    let isTestingEnvironment: Bool\n"
            "                }\n"
        ),
        "new": (
            "                struct AccountPeerKey: Hashable {\n"
            "                    let peerId: EnginePeer.Id\n"
            "                    let isTestingEnvironment: Bool\n"
            "                    // PolySRV: the same user id on two servers is two\n"
            "                    // accounts, and both have to be kept.\n"
            "                    let polySrvScope: String\n"
            "                }\n"
        ),
    },
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift dedup by server scope (contains)",
        "old": (
            "                        if existingAccountPeerKeys.contains(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment)) {\n"
        ),
        "new": (
            "                        if existingAccountPeerKeys.contains(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment, polySrvScope: PolySrvServers.shared.boundScope(forAccount: accountRecord.0))) {\n"
        ),
    },
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift dedup by server scope (insert)",
        "old": (
            "                            existingAccountPeerKeys.insert(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment))\n"
        ),
        "new": (
            "                            existingAccountPeerKeys.insert(AccountPeerKey(peerId: account.peerId, isTestingEnvironment: account.testingEnvironment, polySrvScope: PolySrvServers.shared.boundScope(forAccount: accountRecord.0)))\n"
        ),
    },
    # PolySRV: the account cap counts every server, as desktop's does
    # (min(premiumCount + 20, 50)). Upstream's 3-or-4 limit belongs to the
    # official cloud; here an account normally belongs to a different server, so
    # the client's own cap has to be its own number.
    {
        "file": LOGOUT_OPTIONS_SWIFT,
        "label": "LogoutOptionsController.swift PolySRV account cap",
        "old": (
            "            var maximumAvailableAccounts: Int = 3\n"
            "            if accountAndPeer?.1.isPremium == true && !context.account.testingEnvironment {\n"
            "                maximumAvailableAccounts = 4\n"
            "            }\n"
            "            var count: Int = 1\n"
            "            for (accountContext, peer, _) in accountsAndPeers {\n"
            "                if !accountContext.account.testingEnvironment {\n"
            "                    if peer.isPremium {\n"
            "                        maximumAvailableAccounts = 4\n"
            "                    }\n"
            "                    count += 1\n"
            "                }\n"
            "            }\n"
        ),
        "new": (
            "            // PolySRV: the cap is desktop's and counts every server: 20\n"
            "            // accounts, one more for each premium account, 50 at most.\n"
            "            var premiumCount: Int = 0\n"
            "            if !context.account.testingEnvironment && accountAndPeer?.1.isPremium == true {\n"
            "                premiumCount += 1\n"
            "            }\n"
            "            var count: Int = 1\n"
            "            for (accountContext, peer, _) in accountsAndPeers {\n"
            "                if !accountContext.account.testingEnvironment {\n"
            "                    if peer.isPremium {\n"
            "                        premiumCount += 1\n"
            "                    }\n"
            "                    count += 1\n"
            "                }\n"
            "            }\n"
            "            let maximumAvailableAccounts = PolySrvServers.maximumAccountCount(premiumCount: premiumCount)\n"
        ),
    },
    {
        "file": DELETE_ACCOUNT_OPTIONS_SWIFT,
        "label": "DeleteAccountOptionsController.swift PolySRV account cap",
        "old": (
            "        let canAddAccounts = accountsAndPeers.1.count + 1 < maximumNumberOfAccounts\n"
        ),
        "new": (
            "        let canAddAccounts = accountsAndPeers.1.count + 1 < PolySrvServers.maximumAccountCount(premiumCount: accountsAndPeers.1.filter { $0.1.isPremium }.count)\n"
        ),
    },
    {
        "file": SETTINGS_SEARCHABLE_ITEMS_SWIFT,
        "label": "SettingsSearchableItems.swift PolySRV account cap",
        "old": (
            "        return accountsAndPeers.1.count + 1 < maximumNumberOfAccounts\n"
        ),
        "new": (
            "        return accountsAndPeers.1.count + 1 < PolySrvServers.maximumAccountCount(premiumCount: accountsAndPeers.1.filter { $0.1.isPremium }.count)\n"
        ),
    },
    {
        "file": SHARED_ACCOUNT_CONTEXT_SWIFT,
        "label": "SharedAccountContext.swift import AuthorizationUI",
        "old": (
            "import PeerInfoUI\n"
            "import SettingsUI\n"
        ),
        "new": (
            "import PeerInfoUI\n"
            "import SettingsUI\n"
            "import AuthorizationUI\n"
        ),
    },
    # PolySRV: the native Settings account list, grouped by server, with the
    # server's name as the group header (the official cloud first) - the same
    # shape the Android and Windows clients use.
    {
        "file": SETTINGS_ACCOUNTS_ITEMS_SWIFT,
        "label": "Settings accounts grouped by server",
        "old": (
            "            for (peerAccountContext, peer, badgeCount) in settings.accountsAndPeers {\n"
            "                let mappedContext = ItemListPeerItem.Context.custom(ItemListPeerItem.Context.Custom(\n"
            "                    accountPeerId: peerAccountContext.account.peerId,\n"
            "                    engine: peerAccountContext.engine,\n"
            "                    animationCache: context.animationCache,\n"
            "                    animationRenderer: context.animationRenderer,\n"
            "                    isPremiumDisabled: false,\n"
            "                    resolveInlineStickers: { fileIds in\n"
            "                        return context.engine.stickers.resolveInlineStickers(fileIds: fileIds)\n"
            "                    }\n"
            "                ))\n"
            "                let member: PeerInfoMember = .account(peer: EngineRenderedPeer(peer: peer))\n"
            "                items[.accounts]!.append(PeerInfoScreenMemberItem(id: member.id, context: mappedContext, enclosingPeer: nil, member: member, badge: badgeCount > 0 ? \"\\(compactNumericCountString(Int(badgeCount), decimalSeparator: presentationData.dateTimeFormat.decimalSeparator))\" : nil, isAccount: true, action: { action in\n"
            "                    switch action {\n"
            "                    case .open:\n"
            "                        interaction.switchToAccount(peerAccountContext.account.id)\n"
            "                    case .remove:\n"
            "                        interaction.logoutAccount(peerAccountContext.account.id)\n"
            "                    default:\n"
            "                        break\n"
            "                    }\n"
            "                }, contextAction: { node, gesture in\n"
            "                    interaction.accountContextMenu(peerAccountContext.account.id, node, gesture)\n"
            "                }))\n"
            "            }\n"
        ),
        "new": (
            "            // PolySRV: one section per server, so each server is its own\n"
            "            // glass block with the server's name as the section header.\n"
            "            var polySrvGroups: [(name: String, isTelegram: Bool, entries: [(AccountContext, EnginePeer, Int32)])] = []\n"
            "            for polySrvEntry in settings.accountsAndPeers {\n"
            "                let polySrvName = PolySrvServers.shared.boundServerName(forAccount: polySrvEntry.0.account.id)\n"
            "                let polySrvIsTelegram = PolySrvServers.shared.boundScope(forAccount: polySrvEntry.0.account.id) == PolySrvServers.telegramServerId\n"
            "                if let polySrvIndex = polySrvGroups.firstIndex(where: { $0.name == polySrvName && $0.isTelegram == polySrvIsTelegram }) {\n"
            "                    polySrvGroups[polySrvIndex].entries.append(polySrvEntry)\n"
            "                } else {\n"
            "                    polySrvGroups.append((name: polySrvName, isTelegram: polySrvIsTelegram, entries: [polySrvEntry]))\n"
            "                }\n"
            "            }\n"
            "            polySrvGroups.sort { lhs, rhs in\n"
            "                if lhs.isTelegram != rhs.isTelegram {\n"
            "                    return lhs.isTelegram\n"
            "                }\n"
            "                return lhs.name < rhs.name\n"
            "            }\n"
            "            for polySrvGroup in polySrvGroups {\n"
            "                var polySrvItems: [PeerInfoScreenItem] = [PeerInfoScreenHeaderItem(id: 0, text: polySrvGroup.name)]\n"
            "                for (peerAccountContext, peer, badgeCount) in polySrvGroup.entries {\n"
            "                    let mappedContext = ItemListPeerItem.Context.custom(ItemListPeerItem.Context.Custom(\n"
            "                        accountPeerId: peerAccountContext.account.peerId,\n"
            "                        engine: peerAccountContext.engine,\n"
            "                        animationCache: context.animationCache,\n"
            "                        animationRenderer: context.animationRenderer,\n"
            "                        isPremiumDisabled: false,\n"
            "                        resolveInlineStickers: { fileIds in\n"
            "                            return context.engine.stickers.resolveInlineStickers(fileIds: fileIds)\n"
            "                        }\n"
            "                    ))\n"
            "                    let member: PeerInfoMember = .account(peer: EngineRenderedPeer(peer: peer))\n"
            "                    polySrvItems.append(PeerInfoScreenMemberItem(id: member.id, context: mappedContext, enclosingPeer: nil, member: member, badge: badgeCount > 0 ? \"\\(compactNumericCountString(Int(badgeCount), decimalSeparator: presentationData.dateTimeFormat.decimalSeparator))\" : nil, isAccount: true, action: { action in\n"
            "                        switch action {\n"
            "                        case .open:\n"
            "                            interaction.switchToAccount(peerAccountContext.account.id)\n"
            "                        case .remove:\n"
            "                            interaction.logoutAccount(peerAccountContext.account.id)\n"
            "                        default:\n"
            "                            break\n"
            "                        }\n"
            "                    }, contextAction: { node, gesture in\n"
            "                        interaction.accountContextMenu(peerAccountContext.account.id, node, gesture)\n"
            "                    }))\n"
            "                }\n"
            "                polySrvAccountSections.append((AnyHashable(\"polysrv-accounts-\\(polySrvGroup.name)-\\(polySrvGroup.isTelegram)\"), polySrvItems))\n"
            "            }\n"
        ),
    },
    # PolySRV: a single "All Accounts" entry that opens the overlay's own screen
    # listing every account from every server. It sits outside the "has other
    # accounts" guard, so it is reachable even with a single account.
    {
        "file": SETTINGS_ACCOUNTS_ITEMS_SWIFT,
        "label": "Settings All Accounts entry",
        "old": (
            "            items[.accounts]!.append(PeerInfoScreenActionItem(id: 100, text: presentationData.strings.Settings_AddAccount, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), action: {\n"
            "                interaction.openSettings(.addAccount)\n"
            "            }))\n"
            "        }\n"
        ),
        "new": (
            "            items[.accounts]!.append(PeerInfoScreenActionItem(id: 100, text: presentationData.strings.Settings_AddAccount, icon: PresentationResourcesItemList.plusIconImage(presentationData.theme), action: {\n"
            "                interaction.openSettings(.addAccount)\n"
            "            }))\n"
            "        }\n"
            "        \n"
            "        // PolySRV: always reachable, even with a single account, so every\n"
            "        // account from every server can be seen and switched between.\n"
            "        items[.accounts]!.append(PeerInfoScreenActionItem(id: 101, text: \"All Accounts\", icon: UIImage(bundleImageName: \"Call/Accounts\"), action: {\n"
            "            if let navigationController = context.sharedContext.mainWindow?.viewController as? NavigationController {\n"
            "                navigationController.pushViewController(PolySrvAccountsController(context: context))\n"
            "            }\n"
            "        }))\n"
        ),
    },
    # PolySRV: the accounts groups are collected here and spliced into `result`
    # as their own sections (one glass block per server).
    {
        "file": SETTINGS_ACCOUNTS_ITEMS_SWIFT,
        "label": "Settings accounts: group list local",
        "old": (
            "    var items: [SettingsSection: [PeerInfoScreenItem]] = [:]\n"
            "    for section in SettingsSection.allCases {\n"
            "        items[section] = []\n"
            "    }\n"
        ),
        "new": (
            "    var items: [SettingsSection: [PeerInfoScreenItem]] = [:]\n"
            "    for section in SettingsSection.allCases {\n"
            "        items[section] = []\n"
            "    }\n"
            "    \n"
            "    var polySrvAccountSections: [(AnyHashable, [PeerInfoScreenItem])] = []\n"
        ),
    },
    {
        "file": SETTINGS_ACCOUNTS_ITEMS_SWIFT,
        "label": "Settings accounts: splice per-server sections",
        "old": (
            "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n"
            "    for section in SettingsSection.allCases {\n"
            "        if let sectionItems = items[section], !sectionItems.isEmpty {\n"
            "            result.append((section, sectionItems))\n"
            "        }\n"
            "    }\n"
            "    return result\n"
        ),
        "new": (
            "    var result: [(AnyHashable, [PeerInfoScreenItem])] = []\n"
            "    for section in SettingsSection.allCases {\n"
            "        if section == .accounts {\n"
            "            // PolySRV: one section (one glass block) per server.\n"
            "            for polySrvAccountSection in polySrvAccountSections {\n"
            "                result.append(polySrvAccountSection)\n"
            "            }\n"
            "        }\n"
            "        if let sectionItems = items[section], !sectionItems.isEmpty {\n"
            "            result.append((section, sectionItems))\n"
            "        }\n"
            "    }\n"
            "    return result\n"
        ),
    },
    # PolySRV: Settings -> Add Account is the path that still enforced the
    # official cloud's 3-or-4 limit; it uses the client's own cap too.
    {
        "file": SETTINGS_ACCOUNTS_ACTIONS_SWIFT,
        "label": "PeerInfoScreenSettingsActions.swift PolySRV account cap",
        "old": (
            "                var maximumAvailableAccounts: Int = 3\n"
            "                if accountAndPeer?.1.isPremium == true && !strongSelf.context.account.testingEnvironment {\n"
            "                    maximumAvailableAccounts = 4\n"
            "                }\n"
            "                var count: Int = 1\n"
            "                for (accountContext, peer, _) in accountsAndPeers {\n"
            "                    if !accountContext.account.testingEnvironment {\n"
            "                        if peer.isPremium {\n"
            "                            maximumAvailableAccounts = 4\n"
            "                        }\n"
            "                        count += 1\n"
            "                    }\n"
            "                }\n"
            "                \n"
            "                if count >= maximumAvailableAccounts {\n"
        ),
        "new": (
            "                // PolySRV: the cap is desktop's and counts every server:\n"
            "                // min(premium + 20, 50), not the official cloud's 3-or-4.\n"
            "                var premiumCount: Int = 0\n"
            "                if accountAndPeer?.1.isPremium == true && !strongSelf.context.account.testingEnvironment {\n"
            "                    premiumCount += 1\n"
            "                }\n"
            "                var count: Int = 1\n"
            "                for (accountContext, peer, _) in accountsAndPeers {\n"
            "                    if !accountContext.account.testingEnvironment {\n"
            "                        if peer.isPremium {\n"
            "                            premiumCount += 1\n"
            "                        }\n"
            "                        count += 1\n"
            "                    }\n"
            "                }\n"
            "                let maximumAvailableAccounts = PolySrvServers.maximumAccountCount(premiumCount: premiumCount)\n"
            "                \n"
            "                if count >= maximumAvailableAccounts {\n"
        ),
    },
    # PolySRV: the picker and the add/edit form draw their cards and bar with the
    # app's glass primitive, so AuthorizationUI needs the module.
    {
        "file": "submodules/AuthorizationUI/BUILD",
        "label": "AuthorizationUI BUILD: glass background dependency",
        "old": (
            "        \"//submodules/TelegramUI/Components/GlassBarButtonComponent\",\n"
        ),
        "new": (
            "        \"//submodules/TelegramUI/Components/GlassBarButtonComponent\",\n"
            "        \"//submodules/TelegramUI/Components/GlassBackgroundComponent\",\n"
        ),
    },
    # PolySRV: the per-server account blocks are their own sections, so the
    # renderer's section spacing would leave a full gap between every one of
    # them. Give only those sections a smaller gap; every other Settings section
    # keeps the app's spacing.
    {
        "file": PEERINFO_SCREEN_SWIFT,
        "label": "PeerInfoScreen.swift tighter spacing for account blocks",
        "old": (
            "                if !sectionHeight.isZero && !self.state.isEditing {\n"
            "                    contentHeight += sectionHeight\n"
            "                    contentHeight += sectionSpacing\n"
            "                }\n"
        ),
        "new": (
            "                if !sectionHeight.isZero && !self.state.isEditing {\n"
            "                    contentHeight += sectionHeight\n"
            "                    // PolySRV: the per-server account blocks sit a little\n"
            "                    // closer together than the app's own sections.\n"
            "                    if let polySrvSectionId = sectionId as? String, polySrvSectionId.hasPrefix(\"polysrv-accounts-\") {\n"
            "                        contentHeight += 10.0\n"
            "                    } else {\n"
            "                        contentHeight += sectionSpacing\n"
            "                    }\n"
            "                }\n"
        ),
    },
]
