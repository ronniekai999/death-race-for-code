import AppCore
import LegendsUI
import SwiftUI
import Vault

/// The WRLD window, as the WRLD board draws it: the list down the side, the title row, and
/// the chosen place: host cards with the inspector beside them, or one of the vault's
/// pages (Keys, Wishing Well, Come & Go, Known hosts).
struct WRLDBoardView: View {
    let model: WRLDBoardModel

    var body: some View {
        HStack(spacing: 0) {
            WRLDListView(model: model)
            Rectangle().fill(model.palette.line).frame(width: 1)
            VStack(spacing: 0) {
                WRLDTitleRow(model: model)
                Rectangle().fill(model.palette.line).frame(height: 1)
                switch model.place {
                case .allHosts, .legends, .group:
                    HStack(spacing: 0) {
                        WRLDHostsPage(model: model)
                        if let host = model.selectedHost {
                            Rectangle().fill(model.palette.line).frame(width: 1)
                            WRLDInspector(model: model, host: host)
                                .id(host.id)
                                .frame(width: 330)
                        }
                    }
                case .keys: KeysPage(model: model)
                case .wishingWell: WishingWellPage(model: model)
                case .comeAndGo: ComeAndGoPage(model: model)
                case .knownHosts: KnownHostsPage(model: model)
                }
            }
        }
        .frame(minWidth: 880, minHeight: 560)
        .background(model.palette.ground)
        .ignoresSafeArea()
        .environment(\.legends, model.palette)
        .preferredColorScheme(model.palette.isLight ? .light : .dark)
    }
}

/// The side list: search, the places that hold hosts, the vault's pages, the tagline.
struct WRLDListView: View {
    @Bindable var model: WRLDBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search WRLD", text: $model.query)
                .wrldField()
                .padding(.bottom, 10)
            ForEach(model.hostRows) { row in
                WRLDListRow(row: row, isSelected: model.place == row.place) { model.place = row.place }
            }
            Eyebrow("Vault").padding(.top, 14).padding(.bottom, 4).padding(.horizontal, 10)
            ForEach(model.vaultRows) { row in
                WRLDListRow(row: row, isSelected: model.place == row.place) {
                    model.place = row.place
                    if row.place == .knownHosts || row.place == .keys { model.refreshFiles() }
                }
            }
            Spacer(minLength: 12)
            Tagline()
        }
        // Clear of the traffic lights, which sit over the content.
        .padding(.top, 48)
        .padding(.horizontal, 12)
        .padding(.bottom, 16)
        .frame(width: 214)
        .background(model.palette.groundDeep)
    }
}

struct WRLDListRow: View {
    let row: WRLDBoard.ListRow
    let isSelected: Bool
    let select: () -> Void
    @Environment(\.legends) private var palette

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: row.symbol).frame(width: 18)
                Text(row.title).lineLimit(1)
                Spacer(minLength: 0)
                Text(String(row.count)).foregroundStyle(palette.inkFaint)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? palette.ink : palette.inkMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? palette.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.title), \(row.count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// "WRLD · 11 hosts · 3 keys · 2 tunnels", New host, and the 999.
struct WRLDTitleRow: View {
    let model: WRLDBoardModel

    var body: some View {
        HStack(spacing: 12) {
            Text("WRLD").font(.system(size: 13, weight: .bold)).foregroundStyle(model.palette.ink)
            Text(model.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(model.palette.inkMuted)
            Spacer(minLength: 0)
            Button {
                model.host?.newHost(nil)
            } label: {
                Label("New host", systemImage: "plus")
            }
            .buttonStyle(.wrld(.ghost))
            Wordmark999(size: 20)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

/// Host cards under their headings, and above them the offer to add what ~/.ssh/config
/// names.
struct WRLDHostsPage: View {
    let model: WRLDBoardModel
    private let columns = [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.place == .allHosts, !model.importable.isEmpty, model.query.isEmpty {
                    ImportBanner(model: model)
                }
                if let problem = model.problem {
                    Text(problem).font(.system(size: 12, weight: .medium)).foregroundStyle(model.palette.danger)
                }
                let sections = model.sections
                if sections.isEmpty {
                    EmptyHosts(model: model)
                }
                ForEach(sections) { section in
                    Eyebrow(section.title, count: section.hosts.count)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(section.hosts) { host in
                            HostCardView(model: model, host: host)
                        }
                    }
                }
            }
            .padding(16)
        }
    }
}

/// "Found 12 hosts in ~/.ssh/config", with Add to WRLD and Not Now.
struct ImportBanner: View {
    let model: WRLDBoardModel

    var body: some View {
        let palette = model.palette
        HStack(spacing: 12) {
            Tile(symbol: "list.bullet.rectangle")
            VStack(alignment: .leading, spacing: 2) {
                Text(WRLDBoard.importTitle(count: model.importable.count))
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink)
                Text("They show up here and keep working in plain ssh too. Nothing in the file changes.")
                    .font(.system(size: 12)).foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Not Now") { model.dismissImports() }.buttonStyle(.wrld(.ghost))
            Button("Add to WRLD") { model.importAll() }.buttonStyle(.wrld(.primary))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.line, lineWidth: 1))
    }
}

/// What the hosts page says with nothing to show.
struct EmptyHosts: View {
    let model: WRLDBoardModel

    var body: some View {
        VStack(spacing: 12) {
            Text(model.query.isEmpty ? SidebarModel.emptyHint : "No host matches “\(model.query)”.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.palette.inkMuted)
            if model.query.isEmpty {
                Button("New Host…") { model.host?.newHost(nil) }.buttonStyle(.wrld(.primary))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

/// One host: its name and address, its dot, its chips, what's known of it, and Connect. A
/// click shows it in the inspector; the selected card wears the NeonBorder.
struct HostCardView: View {
    let model: WRLDBoardModel
    let host: WRLDHost

    var body: some View {
        let palette = model.palette
        let status = model.status(of: host)
        let isSelected = model.selected == host.id
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Tile(symbol: host.sshConfigAlias == nil ? "server.rack" : "list.bullet.rectangle")
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.name).font(.system(size: 15, weight: .bold)).foregroundStyle(palette.ink).lineLimit(1)
                    Text(model.address(of: host))
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(palette.inkFaint).lineLimit(1)
                }
                Spacer(minLength: 0)
                StatusDotView(dot: status.dot)
            }
            let chips = model.chips(for: host)
            if !chips.isEmpty {
                FlowLayout {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in ChipView(chip: chip) }
                }
            }
            HStack {
                Text(status.line).font(.system(size: 12)).foregroundStyle(palette.inkMuted).lineLimit(1)
                Spacer(minLength: 8)
                Button("Connect") { model.connect(host) }
                    .buttonStyle(.wrld(isSelected ? .primary : .plain))
            }
        }
        .padding(14)
        .background(shape.fill(palette.surface))
        .overlay {
            if isSelected {
                shape.strokeBorder(palette.borderGradient, lineWidth: 1.5)
            } else {
                shape.strokeBorder(palette.line, lineWidth: 1)
            }
        }
        .shadow(color: isSelected ? palette.glow.opacity(0.35) : .clear, radius: 14)
        .contentShape(shape)
        .onTapGesture { model.selected = isSelected ? nil : host.id }
        .contextMenu { HostMenu(model: model, host: host) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(host.name), \(status.line)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// What a host's context menu offers, on its card and in the sidebar.
struct HostMenu: View {
    let model: WRLDBoardModel
    let host: WRLDHost

    var body: some View {
        Button("Connect") { model.connect(host) }
        Button("Connect Beside") { model.connect(host, beside: true) }
        Divider()
        Button("Edit") {
            switch model.place {
            case .allHosts, .legends, .group: break
            case .keys, .wishingWell, .comeAndGo, .knownHosts: model.place = .allHosts
            }
            model.selected = host.id
        }
        Button(host.isLegend ? "Unpin from Legends" : "Pin to Legends") {
            model.edit { $0.setLegend(host.id, !host.isLegend) }
        }
        Button("Copy Address") { WRLDBoardModel.copy(model.address(of: host)) }
        Divider()
        Button("Remove from WRLD…", role: .destructive) { WRLDRemoval.confirm(host, in: model) }
    }
}
