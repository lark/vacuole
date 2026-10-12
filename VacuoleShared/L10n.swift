// Copyright 2026 Wang Jian
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Localized string lookup shared by the GUI and the daemon.
///
/// Language resolution follows the host environment: any Chinese locale
/// (Simplified or Traditional) uses the Chinese table, everything else uses English.
public enum L10n {

    public enum Language {
        case chinese
        case english
    }

    public static let current: Language = resolve()

    private static func resolve() -> Language {
        for identifier in Locale.preferredLanguages {
            let lower = identifier.lowercased()
            if lower.hasPrefix("zh") { return .chinese }
            if lower.hasPrefix("en") { return .english }
        }
        return .english
    }

    public static func string(_ key: String) -> String {
        switch current {
        case .chinese: return zh[key] ?? en[key] ?? key
        case .english: return en[key] ?? key
        }
    }

    /// English table (serves as the fallback for any missing key).
    static let en: [String: String] = [
        "app.name": "vacuole",

        // Menu bar
        "ui.menu.daemonConnected": "Daemon: connected",
        "ui.menu.daemonDisconnected": "Daemon: not connected / not installed",
        "ui.menu.errorFormat": "Error: %@",
        "ui.menu.currentConfigFormat": "Current config: %@",
        "ui.menu.noConfigs": "(No imported configs)",
        "ui.menu.dnsFormat": "DNS: %@",
        "ui.menu.domainSetFormat": "Domain set: %@",
        "ui.menu.domainSetInactive": "Domain set: inactive",
        "ui.menu.switchDomainSet": "Switch Domain Set",
        "ui.menu.openSettings": "Open Settings…",
        "ui.menu.reconnectDaemon": "Reconnect Daemon",
        "ui.menu.quit": "Quit vacuole",

        // Common actions / status
        "ui.action.import": "Import",
        "ui.action.delete": "Delete",
        "ui.action.cancel": "Cancel",
        "ui.action.add": "Add",
        "ui.action.refresh": "Refresh",
        "ui.action.apply": "Apply",
        "ui.status.running": "Running",
        "ui.status.starting": "Starting",
        "ui.status.stopping": "Stopping",
        "ui.status.stopped": "Stopped",
        "ui.status.error": "Error",
        "ui.window.settingsTitle": "vacuole Settings",

        // Tabs
        "ui.tab.tunnel": "Tunnel",
        "ui.tab.domainSets": "Domain Sets",
        "ui.tab.staticRoutes": "Static Routes",
        "ui.tab.network": "Network / DNS",
        "ui.tab.logs": "Status / Logs",

        // Tunnel
        "ui.tunnel.start": "Start Tunnel",
        "ui.tunnel.stop": "Stop Tunnel",
        "ui.tunnel.startingEllipsis": "Starting…",
        "ui.tunnel.stoppingEllipsis": "Stopping…",
        "ui.tunnel.importFromFile": "From File",
        "ui.tunnel.configContent": "Config Content",
        "ui.tunnel.configsTitle": "Configs",
        "ui.tunnel.revealKey": "Show private key",
        "ui.tunnel.hideKey": "Hide private key",
        "ui.tunnel.noConfigSelected": "No Config Selected",
        "ui.tunnel.selectConfigHint": "Select a config on the left, or import a new one",
        "ui.tunnel.importTitle": "Import WireGuard Config",
        "ui.tunnel.configNamePlaceholder": "Config name",
        "ui.tunnel.rename": "Rename",

        // Domain sets
        "ui.domainSets.activated": "Active",
        "ui.domainSets.setsTitle": "Domain Sets",
        "ui.domainSets.groupDomainCount": "%d groups · %d domains",
        "ui.domainSets.newSetNamePlaceholder": "New set name",
        "ui.domainSets.noSetSelected": "No Domain Set Selected",
        "ui.domainSets.selectSetHint": "Select or create a domain set on the left",
        "ui.domainSets.setNamePlaceholder": "Set name",
        "ui.domainSets.searchPlaceholder": "Search domains (global)",
        "ui.domainSets.currentlyActive": "Currently Active",
        "ui.domainSets.activate": "Activate This Domain Set",
        "ui.domainSets.groups": "Domain Groups",
        "ui.domainSets.newGroupNamePlaceholder": "New group name",
        "ui.domainSets.groupNamePlaceholder": "New group name",
        "ui.domainSets.domainCount": "%d domains",
        "ui.domainSets.domainPlaceholder": "Enter domain (supports *.example.com wildcards)",
        "ui.domainSets.moreHidden": "… %d more not shown (search to filter)",
        "ui.domainSets.importTitle": "Bulk Import Domains",
        "ui.domainSets.parsedCount": "Parsed %d domains",
        "ui.domainSets.importToGroup": "Import into group",
        "ui.domainSets.newGroupOption": "(New group)",

        // Static routes
        "ui.routes.splittingActive": "Split routing enabled (routes via tunnel)",
        "ui.routes.splittingInactive": "Split routing disabled (tunnel not running)",
        "ui.routes.staticTitle": "Static Routes (CIDR)",
        "ui.routes.cidrPlaceholder": "e.g. 10.0.0.0/8 or 192.168.1.0/24",
        "ui.routes.invalidCIDR": "Invalid format; must be CIDR notation",
        "ui.routes.issuedTitle": "Issued Routes (DNS hits, aggregated to IPv4 /24 and IPv6 /64, reclaimed by TTL)",
        "ui.routes.issuedEmpty": "No matched routes yet (appear after starting the tunnel and visiting domains in the set)",

        // Network / DNS
        "ui.network.dnsProxy": "DNS Proxy",
        "ui.network.stopDNS": "Stop DNS",
        "ui.network.startDNS": "Start DNS",
        "ui.network.autoStartDNS": "Auto-start DNS proxy when tunnel starts",
        "ui.network.dnsNotice": "Note: starting DNS changes the system default DNS to 127.0.0.1; it is restored automatically on stop or exit.",
        "ui.network.capturedTitle": "Captured Physical DNS Servers",
        "ui.network.notCaptured": "Not captured yet",
        "ui.network.upstreamTitle": "DNS Servers",
        "ui.network.customTitle": "Upstream DNS",
        "ui.network.modeTunnel": "Use Tunnel DNS",
        "ui.network.modeCustom": "Custom",
        "ui.network.tunnelNone": "The active tunnel declares no DNS; the default 1.1.1.1 / 8.8.8.8 is used.",
        "ui.network.effective": "In effect: %@",
        "ui.network.notConfigured": "Not configured",
        "ui.network.needUpstream": "At least one upstream DNS server is required",
        "ui.network.upstreamPlaceholder": "e.g. 1.1.1.1",
        "ui.network.ttlTitle": "Route Expiry",
        "ui.network.routeLifetime": "DNS-matched route lifetime",
        "ui.network.seconds": "seconds",
        "ui.network.ttlRange": "Range 60–43200 seconds (up to 12 hours), default 600. Existing matched routes restart their timer with the new value; expired ones are reclaimed by the daemon.",
        "ui.network.dnsTakenOver": "Running · System DNS taken over (127.0.0.1)",
        "ui.network.ttlNotNumber": "TTL must be a number",
        "ui.dns.runningActivated": "Running (taken over)",
        "ui.dns.stopped": "Stopped",

        // Logs
        "ui.logs.title": "Daemon Logs (latest %d)",
        "ui.logs.autoRefresh": "Auto-refresh (2s)",
        "ui.logs.empty": "No logs yet",
        "ui.logs.emptyHint": "Once the daemon runs, tunnel, route, DNS, and domain set activity will appear here",

        // Errors surfaced in the UI
        "ui.error.xpcProxy": "Failed to create XPC proxy",
        "ui.error.importFailed": "Import failed",
        "ui.error.deleteFailed": "Delete failed",
        "ui.error.renameFailed": "Rename failed",
        "ui.error.startFailed": "Start failed",
        "ui.error.stopFailed": "Stop failed",
        "ui.error.addFailed": "Add failed",
        "ui.error.setTTLFailed": "Failed to set TTL",
        "ui.error.dnsStartFailed": "Failed to start DNS",
        "ui.error.dnsStopFailed": "Failed to stop DNS",
        "ui.error.setUpstreamFailed": "Failed to set upstream DNS",
        "ui.error.encodeDomainSet": "Failed to encode domain set",
        "ui.error.saveFailed": "Save failed",
        "ui.error.activateFailed": "Activate failed",

        // Daemon messages
        "daemon.config.createDirFailed": "Cannot create config directory %@: %@",
        "daemon.config.missingInterfaceSection": "Config is missing the [Interface] section",
        "daemon.config.missingPeerSection": "Config is missing the [Peer] section",
        "daemon.config.writeFailed": "Failed to write config file: %@",
        "daemon.config.notFound": "Config %@ not found",
        "daemon.config.deleteFailed": "Delete failed: %@",
        "daemon.config.renameEmpty": "Config name cannot be empty",
        "daemon.config.renameInvalid": "Config name cannot contain \"/\" or line breaks",
        "daemon.config.renameExists": "A config named %@ already exists",
        "daemon.config.renameFailed": "Rename failed: %@",
        "daemon.config.readDirFailed": "Failed to read directory: %@",
        "daemon.config.encodeFailed": "Encoding failed",
        "daemon.tunnel.alreadyRunning": "Tunnel is already running or starting",
        "daemon.tunnel.wireguardGoMissing": "wireguard-go binary not found (place it in the app bundle or /opt/homebrew/bin)",
        "daemon.tunnel.wgMissing": "wg binary not found (place it in the app bundle or /opt/homebrew/bin)",
        "daemon.tunnel.addressMissing": "Config is missing the Address field",
        "daemon.tunnel.peerPublicKeyMissing": "Config is missing [Peer] PublicKey",
        "daemon.tunnel.wireguardGoStartFailed": "Failed to start wireguard-go: %@",
        "daemon.tunnel.ifnameUnavailable": "Cannot obtain the utun interface name",
        "daemon.tunnel.writeTempConfigFailed": "Failed to write temporary config: %@",
        "daemon.tunnel.setconfFailed": "wg setconf failed: %@",
        "daemon.tunnel.ifconfigAddrFailed": "ifconfig address configuration failed: %@",
        "daemon.tunnel.ifconfigUpFailed": "ifconfig up failed: %@",
        "daemon.tunnel.notRunning": "Tunnel is not running",
        "daemon.route.tunnelNotRunning": "Tunnel is not running",
        "daemon.route.invalidIP": "Invalid IP: %@",
        "daemon.route.invalidCIDR": "Invalid CIDR: %@",
        "daemon.domainSet.notFound": "Domain set not found",
        "daemon.domainSet.parseFailed": "Failed to parse domain set: %@",
        "daemon.domainSet.invalidId": "Invalid domain set ID",
        "daemon.dns.physicalNotFound": "No physical DNS servers captured",
        "daemon.dns.takeoverFailed": "Failed to take over system DNS: %@",
        "daemon.dns.serializeFailed": "Serialization failed",
        "daemon.dns.needUpstream": "At least one upstream DNS server is required",
        "daemon.dns.invalidUpstreamMode": "Invalid upstream DNS mode",
        "daemon.dns.noPhysicalDNSForTakeover": "No physical DNS servers captured, cannot take over",
        "daemon.dns.noActiveService": "No active network service found",
        "daemon.dns.setServiceDNSFailed": "Failed to set DNS for %@: %@",
        "daemon.log.encodeFailed": "Failed to encode logs",
    ]

    /// Simplified Chinese table (Traditional locales use it as well).
    static let zh: [String: String] = [
        "app.name": "vacuole",

        // Menu bar
        "ui.menu.daemonConnected": "守护进程：已连接",
        "ui.menu.daemonDisconnected": "守护进程：未连接 / 未安装",
        "ui.menu.errorFormat": "错误：%@",
        "ui.menu.currentConfigFormat": "当前配置：%@",
        "ui.menu.noConfigs": "（无已导入配置）",
        "ui.menu.dnsFormat": "DNS：%@",
        "ui.menu.domainSetFormat": "域名集：%@",
        "ui.menu.domainSetInactive": "域名集：未激活",
        "ui.menu.switchDomainSet": "切换域名集",
        "ui.menu.openSettings": "打开设置…",
        "ui.menu.reconnectDaemon": "重新连接守护进程",
        "ui.menu.quit": "退出 vacuole",

        // Common actions / status
        "ui.action.import": "导入",
        "ui.action.delete": "删除",
        "ui.action.cancel": "取消",
        "ui.action.add": "添加",
        "ui.action.refresh": "刷新",
        "ui.action.apply": "应用",
        "ui.status.running": "运行中",
        "ui.status.starting": "启动中",
        "ui.status.stopping": "停止中",
        "ui.status.stopped": "已停止",
        "ui.status.error": "错误",
        "ui.window.settingsTitle": "vacuole 设置",

        // Tabs
        "ui.tab.tunnel": "隧道",
        "ui.tab.domainSets": "域名集",
        "ui.tab.staticRoutes": "静态路由",
        "ui.tab.network": "网络 / DNS",
        "ui.tab.logs": "状态 / 日志",

        // Tunnel
        "ui.tunnel.start": "启动隧道",
        "ui.tunnel.stop": "停止隧道",
        "ui.tunnel.startingEllipsis": "启动中…",
        "ui.tunnel.stoppingEllipsis": "停止中…",
        "ui.tunnel.importFromFile": "从文件",
        "ui.tunnel.configContent": "配置内容",
        "ui.tunnel.configsTitle": "配置",
        "ui.tunnel.revealKey": "显示私钥",
        "ui.tunnel.hideKey": "隐藏私钥",
        "ui.tunnel.noConfigSelected": "未选择配置",
        "ui.tunnel.selectConfigHint": "从左侧选择一个配置，或导入新配置",
        "ui.tunnel.importTitle": "导入 WireGuard 配置",
        "ui.tunnel.configNamePlaceholder": "配置名称",
        "ui.tunnel.rename": "重命名",

        // Domain sets
        "ui.domainSets.activated": "已激活",
        "ui.domainSets.setsTitle": "域名集",
        "ui.domainSets.groupDomainCount": "%d 组 · %d 域名",
        "ui.domainSets.newSetNamePlaceholder": "新建集合名称",
        "ui.domainSets.noSetSelected": "未选择域名集",
        "ui.domainSets.selectSetHint": "从左侧选择或新建一个域名集",
        "ui.domainSets.setNamePlaceholder": "集合名称",
        "ui.domainSets.searchPlaceholder": "搜索域名（全局）",
        "ui.domainSets.currentlyActive": "当前激活",
        "ui.domainSets.activate": "激活此域名集",
        "ui.domainSets.groups": "域名组",
        "ui.domainSets.newGroupNamePlaceholder": "新建分组名称",
        "ui.domainSets.groupNamePlaceholder": "新分组名称",
        "ui.domainSets.domainCount": "%d 域名",
        "ui.domainSets.domainPlaceholder": "输入域名（支持 *.example.com 通配）",
        "ui.domainSets.moreHidden": "… 另有 %d 条未显示（可搜索过滤）",
        "ui.domainSets.importTitle": "批量导入域名",
        "ui.domainSets.parsedCount": "解析到 %d 条域名",
        "ui.domainSets.importToGroup": "导入到分组",
        "ui.domainSets.newGroupOption": "（新建分组）",

        // Static routes
        "ui.routes.splittingActive": "分流已启用（路由经隧道）",
        "ui.routes.splittingInactive": "分流未启用（隧道未运行）",
        "ui.routes.staticTitle": "静态路由（CIDR）",
        "ui.routes.cidrPlaceholder": "如 10.0.0.0/8 或 192.168.1.0/24",
        "ui.routes.invalidCIDR": "格式不正确，应为 CIDR 表示法",
        "ui.routes.issuedTitle": "已下发路由（DNS 命中，聚合为 IPv4 /24 与 IPv6 /64，按 TTL 回收）",
        "ui.routes.issuedEmpty": "暂无命中路由（启动隧道并访问域名集内的域名后出现）",

        // Network / DNS
        "ui.network.dnsProxy": "DNS 代理",
        "ui.network.stopDNS": "停止 DNS",
        "ui.network.startDNS": "启动 DNS",
        "ui.network.autoStartDNS": "启动隧道时自动启动 DNS 代理",
        "ui.network.dnsNotice": "注意：启动 DNS 会将系统默认 DNS 改为 127.0.0.1，停止或退出时自动还原。",
        "ui.network.capturedTitle": "捕获的物理 DNS 服务器",
        "ui.network.notCaptured": "尚未捕获",
        "ui.network.upstreamTitle": "DNS 服务器",
        "ui.network.customTitle": "上游 DNS",
        "ui.network.modeTunnel": "使用隧道 DNS",
        "ui.network.modeCustom": "自定义",
        "ui.network.tunnelNone": "当前隧道未声明 DNS，将使用默认 1.1.1.1 / 8.8.8.8。",
        "ui.network.effective": "当前生效：%@",
        "ui.network.notConfigured": "未配置",
        "ui.network.needUpstream": "至少需要一个上游 DNS 服务器",
        "ui.network.upstreamPlaceholder": "如 1.1.1.1",
        "ui.network.ttlTitle": "路由过期时间",
        "ui.network.routeLifetime": "DNS 命中路由存活",
        "ui.network.seconds": "秒",
        "ui.network.ttlRange": "范围 60–43200 秒（最长 12 小时），默认 600。已存在的命中路由会按新值重新计时；过期后由守护进程自动回收。",
        "ui.network.dnsTakenOver": "运行中 · 系统 DNS 已接管（127.0.0.1）",
        "ui.network.ttlNotNumber": "TTL 必须是数字",
        "ui.dns.runningActivated": "运行中（已接管）",
        "ui.dns.stopped": "停止",

        // Logs
        "ui.logs.title": "守护进程日志（最近 %d 条）",
        "ui.logs.autoRefresh": "自动刷新（2s）",
        "ui.logs.empty": "暂无日志",
        "ui.logs.emptyHint": "守护进程运行后，这里将显示隧道、路由、DNS 与域名集的活动记录",

        // Errors surfaced in the UI
        "ui.error.xpcProxy": "无法创建 XPC 代理",
        "ui.error.importFailed": "导入失败",
        "ui.error.deleteFailed": "删除失败",
        "ui.error.renameFailed": "重命名失败",
        "ui.error.startFailed": "启动失败",
        "ui.error.stopFailed": "停止失败",
        "ui.error.addFailed": "添加失败",
        "ui.error.setTTLFailed": "设置 TTL 失败",
        "ui.error.dnsStartFailed": "DNS 启动失败",
        "ui.error.dnsStopFailed": "DNS 停止失败",
        "ui.error.setUpstreamFailed": "设置上游 DNS 失败",
        "ui.error.encodeDomainSet": "编码域名集失败",
        "ui.error.saveFailed": "保存失败",
        "ui.error.activateFailed": "激活失败",

        // Daemon messages
        "daemon.config.createDirFailed": "无法创建配置目录 %@: %@",
        "daemon.config.missingInterfaceSection": "配置缺少 [Interface] 段",
        "daemon.config.missingPeerSection": "配置缺少 [Peer] 段",
        "daemon.config.writeFailed": "写入配置文件失败: %@",
        "daemon.config.notFound": "配置 %@ 不存在",
        "daemon.config.deleteFailed": "删除失败: %@",
        "daemon.config.renameEmpty": "配置名称不能为空",
        "daemon.config.renameInvalid": "配置名称不能包含“/”或换行",
        "daemon.config.renameExists": "已存在名为 %@ 的配置",
        "daemon.config.renameFailed": "重命名失败: %@",
        "daemon.config.readDirFailed": "读取目录失败: %@",
        "daemon.config.encodeFailed": "编码失败",
        "daemon.tunnel.alreadyRunning": "隧道已在运行或启动中",
        "daemon.tunnel.wireguardGoMissing": "未找到 wireguard-go 二进制（请将其放入 app bundle 或 /opt/homebrew/bin）",
        "daemon.tunnel.wgMissing": "未找到 wg 二进制（请将其放入 app bundle 或 /opt/homebrew/bin）",
        "daemon.tunnel.addressMissing": "配置缺少 Address 字段",
        "daemon.tunnel.peerPublicKeyMissing": "配置缺少 [Peer] PublicKey",
        "daemon.tunnel.wireguardGoStartFailed": "启动 wireguard-go 失败: %@",
        "daemon.tunnel.ifnameUnavailable": "无法获取 utun 接口名",
        "daemon.tunnel.writeTempConfigFailed": "写入临时配置失败: %@",
        "daemon.tunnel.setconfFailed": "wg setconf 失败: %@",
        "daemon.tunnel.ifconfigAddrFailed": "ifconfig 配置地址失败: %@",
        "daemon.tunnel.ifconfigUpFailed": "ifconfig up 失败: %@",
        "daemon.tunnel.notRunning": "隧道未在运行",
        "daemon.route.tunnelNotRunning": "隧道未运行",
        "daemon.route.invalidIP": "非法 IP: %@",
        "daemon.route.invalidCIDR": "非法 CIDR: %@",
        "daemon.domainSet.notFound": "域名集不存在",
        "daemon.domainSet.parseFailed": "解析域名集失败: %@",
        "daemon.domainSet.invalidId": "无效的域名集 ID",
        "daemon.dns.physicalNotFound": "未捕获到物理 DNS 服务器",
        "daemon.dns.takeoverFailed": "接管系统 DNS 失败: %@",
        "daemon.dns.serializeFailed": "序列化失败",
        "daemon.dns.needUpstream": "至少需要一个上游 DNS 服务器",
        "daemon.dns.invalidUpstreamMode": "上游 DNS 模式无效",
        "daemon.dns.noPhysicalDNSForTakeover": "未捕获到物理 DNS 服务器，无法接管",
        "daemon.dns.noActiveService": "未找到活动网络服务",
        "daemon.dns.setServiceDNSFailed": "设置 %@ DNS 失败: %@",
        "daemon.log.encodeFailed": "编码日志失败",
    ]
}

/// Shorthand for a localized string.
public func L(_ key: String) -> String {
    L10n.string(key)
}

/// Shorthand for a localized format string. Use `%d`, `%@`, ... placeholders in the table.
public func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(key), arguments: args)
}