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
            "            // PolySRV: a non-Telegram account points every datacenter at its\n"
            "            // own server. The public key replaces the built-in one for non-CDN\n"
            "            // datacenters, and a single-machine server locks its endpoints so\n"
            "            // help.getConfig cannot rewrite them.\n"
            "            let polySrvServer = PolySrvServers.shared.server(forAccount: accountId)\n"
            "            if let polySrvServer = polySrvServer, !polySrvServer.isTelegram {\n"
            "                apiEnvironment.customServerPublicKey = polySrvServer.rsaPublicKey.isEmpty ? nil : polySrvServer.rsaPublicKey\n"
            "                apiEnvironment.datacenterOptionsLocked = !polySrvServer.multiDc\n"
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
            "        if PolySrvServers.shared.server(forAccount: self.account.id) == nil {\n"
            "            let picker = PolySrvServerSelectController(servers: servers, theme: self.presentationData.theme, onSelect: { [weak self] server in\n"
            "                guard let strongSelf = self else {\n"
            "                    return\n"
            "                }\n"
            "                strongSelf.polySrvApplyAndContinue(serverId: server.id)\n"
            "            }, onCancel: { [weak self] in\n"
            "                guard let strongSelf = self else {\n"
            "                    return\n"
            "                }\n"
            "                strongSelf.polySrvSetPhoneEntryState()\n"
            "            })\n"
            "            self.presentOverlay(controller: picker, inGlobal: true, blockInteraction: true)\n"
            "            return\n"
            "        }\n"
            "        self.polySrvSetPhoneEntryState()\n"
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
            "    private func phoneEntryController(countryCode: Int32, number: String, splashController: AuthorizationSequenceSplashController?) -> AuthorizationSequencePhoneEntryController {\n"
        ),
    },
]
