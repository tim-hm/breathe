import BreatheKit
import BreatheUI
import SwiftUI

/// The whole of the leaderboard opt-in: type a name and you are on them; clear
/// it and you are not.
///
/// Said plainly rather than as a toggle labelled "privacy", because that is
/// literally how it works — the server lists only profiles that carry a name,
/// and it never invents one.
struct LeaderboardNameView: View {
    @State private var model: LeaderboardNameModel
    @Environment(\.dismiss) private var dismiss

    init(profiles: ProfileStore) {
        _model = State(wrappedValue: LeaderboardNameModel(store: profiles))
    }

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                TextField("Name", text: $model.displayName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
            } header: {
                Text("Display name")
            } footer: {
                Text(
                    "This is the only thing other people see — no goals, no notes, no history. "
                        + "Leave it empty and you stay invisible on every board while still "
                        + "seeing your own place. If somebody already has the name, we'll add a "
                        + "number to yours."
                )
            }
            .listRowBackground(Theme.Surface.raised)

            Section {
                Picker("Born", selection: $model.birthYearBand) {
                    Text("Rather not say").tag(BirthYearBand?.none)
                    ForEach(BirthYearBand.allCases) { band in
                        Text(band.title).tag(BirthYearBand?.some(band))
                    }
                }
            } footer: {
                Text("Optional. It only decides which decade's board you can compare within.")
            }
            .listRowBackground(Theme.Surface.raised)
        }
        .paletteGround()
        .navigationTitle("Your name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    Task {
                        await model.save()
                        dismiss()
                    }
                }
                .disabled(!model.canSave)
            }
        }
    }
}
