import SwiftUI

/// Size / milk / syrup choices shown when adding an item that has options.
struct OptionSheet: View {
  let item: MenuItem
  let venue: Venue
  let onAdd: ([CartOption]) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var selected: [UUID: Set<UUID>] = [:]

  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top, spacing: 14) {
        ItemPhoto(url: item.imageURL)
          .frame(width: 64, height: 64)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        VStack(alignment: .leading, spacing: 3) {
          Text(item.title)
            .font(.app(size: 22, weight: .heavy))
            .foregroundStyle(AppColors.text)
          if let detail = item.detailLine {
            Text(detail)
              .font(.app(size: 15))
              .foregroundStyle(AppColors.mutedText)
          }
        }
        Spacer()
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.app(size: 13, weight: .bold))
            .foregroundStyle(AppColors.text)
            .frame(width: 32, height: 32)
            .background(AppColors.chipFill)
            .clipShape(Circle())
        }
        .accessibilityLabel("Close")
      }
      .padding(.horizontal, 20)
      .padding(.top, 22)
      .padding(.bottom, 8)

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          ForEach(item.optionGroups) { group in
            groupView(group)
          }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
      }

      Button(action: add) {
        HStack {
          Text("Add to basket")
            .font(.app(size: 18, weight: .bold))
          Spacer()
          Text(Money.format(cents: unitCents, currency: item.currency))
            .font(.app(size: 18, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .frame(height: 56)
        .background(canAdd ? AppColors.primary : AppColors.primary.opacity(0.4))
        .clipShape(Capsule())
      }
      .buttonStyle(.plain)
      .disabled(!canAdd)
      .padding(.horizontal, 20)
      .padding(.bottom, 12)
      .accessibilityIdentifier("option-add")
    }
    .background(Color.white)
    .onAppear(perform: preselect)
  }

  private func groupView(_ group: OptionGroup) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(group.title)
          .font(.app(size: 18, weight: .bold))
          .foregroundStyle(AppColors.text)
        Spacer()
        Text(group.isRequired ? "Required" : (group.allowsMultiple ? "Choose any" : "Optional"))
          .font(.app(size: 13, weight: .semibold))
          .foregroundStyle(group.isRequired ? AppColors.primary : AppColors.mutedText)
      }
      .padding(.bottom, 4)

      ForEach(group.options) { option in
        let isOn = selected[group.id]?.contains(option.id) == true
        Button { toggle(option, in: group) } label: {
          HStack(spacing: 12) {
            marker(isOn: isOn, square: group.allowsMultiple)
            Text(option.title)
              .font(.app(size: 17))
              .foregroundStyle(AppColors.text)
            Spacer()
            if option.priceDeltaCents > 0 {
              Text("+" + Money.format(cents: option.priceDeltaCents, currency: item.currency))
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.mutedText)
            }
          }
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
  }

  private func marker(isOn: Bool, square: Bool) -> some View {
    ZStack {
      if square {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(isOn ? AppColors.primary : AppColors.border, lineWidth: 1.5)
          .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isOn ? AppColors.primary : .clear))
          .frame(width: 24, height: 24)
        if isOn { Image(systemName: "checkmark").font(.app(size: 12, weight: .bold)).foregroundStyle(.white) }
      } else {
        Circle()
          .stroke(isOn ? AppColors.primary : AppColors.border, lineWidth: 1.5)
          .frame(width: 24, height: 24)
        if isOn { Circle().fill(AppColors.primary).frame(width: 13, height: 13) }
      }
    }
  }

  // MARK: - State

  private func preselect() {
    guard selected.isEmpty else { return }
    for group in item.optionGroups where group.isRequired && !group.allowsMultiple {
      if let first = group.options.first { selected[group.id] = [first.id] }
    }
  }

  private func toggle(_ option: MenuOption, in group: OptionGroup) {
    var current = selected[group.id] ?? []
    if group.allowsMultiple {
      if current.contains(option.id) { current.remove(option.id) } else { current.insert(option.id) }
    } else if current.contains(option.id) {
      // Tapping the chosen option clears it, unless the group is required.
      if !group.isRequired { current = [] }
    } else {
      current = [option.id]
    }
    selected[group.id] = current
  }

  private var chosen: [CartOption] {
    item.optionGroups.flatMap { group in
      group.options.filter { selected[group.id]?.contains($0.id) == true }.map {
        CartOption(id: $0.id, group: group.title, title: $0.title, priceDeltaCents: $0.priceDeltaCents)
      }
    }
  }

  private var unitCents: Int { item.priceCents + chosen.reduce(0) { $0 + $1.priceDeltaCents } }

  private var canAdd: Bool {
    item.optionGroups.allSatisfy { !$0.isRequired || !(selected[$0.id] ?? []).isEmpty }
  }

  private func add() {
    onAdd(chosen)
    dismiss()
  }
}
