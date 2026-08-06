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
    let profiles: ProfileStore

    @State private var displayName = ""
    @State private var birthYearBand: BirthYearBand?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $displayName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: displayName) { _, new in
                        displayName = clamped(new)
                    }
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
                Picker("Born", selection: $birthYearBand) {
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
        .scrollContentBackground(.hidden)
        .paletteGround()
        .navigationTitle("Your name")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(isSaving || !isValid)
            }
        }
        .onAppear {
            displayName = profiles.profile.displayName
            birthYearBand = profiles.profile.birthYearBand
        }
    }

    /// Empty is always allowed — it means "take me off the boards" — and any
    /// other value has to clear the server's minimum before Save does anything.
    private var isValid: Bool {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.unicodeScalars.count >= Profile.minDisplayNameLength
    }

    /// Counted in Unicode scalars, not `Character`s, because that is the unit
    /// the server's validation and the column `CHECK` both use: a
    /// grapheme-cluster count would let through a name of multi-scalar emoji
    /// the server then rejects.
    private func clamped(_ value: String) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > Profile.maxDisplayNameLength else { return value }

        let end = scalars.index(scalars.startIndex, offsetBy: Profile.maxDisplayNameLength)
        return String(scalars[..<end])
    }

    /// Awaits the save, unlike onboarding's: the server may hand back a
    /// suffixed name, and somebody should see that here rather than discover it
    /// on a board later. A failure still dismisses — the answer is stored
    /// locally and the next launch retries it.
    private func save() {
        isSaving = true

        var profile = profiles.profile
        profile.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        profile.birthYearBand = birthYearBand

        Task {
            await profiles.save(profile)
            isSaving = false
            dismiss()
        }
    }
}
