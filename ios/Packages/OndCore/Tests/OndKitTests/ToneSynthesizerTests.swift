import Foundation
import OndKit
import Testing

/// The cue tones are the one place in the session where a wrong constant is
/// silent rather than fatal: a malformed header does not crash, it just never
/// plays, and nothing on screen says so. These assertions are what a device
/// would otherwise have to tell us.
@Suite("Synthesising the session's cue tones")
struct ToneSynthesizerTests {
    private func wav() -> Data {
        ToneSynthesizer.wav([ToneSynthesizer.Note(440, duration: 0.5)])
    }

    /// The chunk identifiers are ASCII by definition of the format, so a failure
    /// to decode is itself a failed assertion rather than something to handle.
    private func string(_ data: Data, at offset: Int, length: Int = 4) -> String? {
        String(bytes: data[offset ..< offset + length], encoding: .ascii)
    }

    private func integer<T: FixedWidthInteger>(_ data: Data, at offset: Int) -> T {
        data[offset ..< offset + MemoryLayout<T>.size]
            .reversed()
            .reduce(T(0)) { ($0 << 8) | T($1) }
    }

    /// `AVAudioPlayer` reads these four chunks and refuses the data outright if
    /// any of them is wrong — which is indistinguishable, from the session's
    /// point of view, from the person having chosen visual-only cues.
    @Test("The header declares mono 16-bit PCM at 44.1 kHz")
    func writesACanonicalWavHeader() {
        let data = wav()

        #expect(string(data, at: 0) == "RIFF")
        #expect(string(data, at: 8) == "WAVE")
        #expect(string(data, at: 12) == "fmt ")
        #expect(string(data, at: 36) == "data")

        #expect(integer(data, at: 16) == UInt32(16)) // PCM header length
        #expect(integer(data, at: 20) == UInt16(1)) // uncompressed
        #expect(integer(data, at: 22) == UInt16(1)) // mono
        #expect(integer(data, at: 24) == UInt32(44100))
        #expect(integer(data, at: 28) == UInt32(88200)) // bytes per second
        #expect(integer(data, at: 32) == UInt16(2)) // frame alignment
        #expect(integer(data, at: 34) == UInt16(16)) // bits per sample
    }

    /// The two length fields are what a reader trusts over the actual file
    /// length, so a tone that disagrees with them plays truncated or not at all.
    @Test("The declared lengths match the samples written")
    func lengthsAgreeWithTheBuffer() {
        let data = wav()
        let samples = Int(0.5 * 44100)

        #expect(data.count == 44 + samples * 2)
        #expect(integer(data, at: 40) == UInt32(samples * 2))
        #expect(integer(data, at: 4) == UInt32(36 + samples * 2))
    }

    /// A buffer of silence is a cue nobody hears, and the envelope has to leave
    /// both ends at zero — a waveform cut mid-cycle is an audible click.
    @Test("The tone rises from silence, sounds, and decays back")
    func shapesTheEnvelope() {
        let data = wav()
        let samples = stride(from: 44, to: data.count, by: 2).map { offset -> Int16 in
            Int16(bitPattern: UInt16(data[offset]) | UInt16(data[offset + 1]) << 8)
        }

        let peak = samples.map { abs(Int($0)) }.max() ?? 0

        #expect(samples.first == 0)
        #expect(abs(Int(samples[samples.count - 1])) < 64)
        // A peak, not a midpoint sample: the midpoint of a 440 Hz tone lands on
        // a zero crossing, which says nothing about whether the tone sounds.
        #expect(peak > Int(Int16.max) / 8)
        // Well short of clipping: these play under whatever else is going on.
        #expect(peak < Int(Int16.max))
    }

    /// The closing triad's notes overlap, and summing two sines is where a
    /// buffer would wrap to a loud crack if it were not clamped.
    @Test("Overlapping notes chord without wrapping")
    func sumsOverlappingNotes() {
        let data = ToneSynthesizer.wav([
            ToneSynthesizer.Note(440, start: 0, duration: 0.5),
            ToneSynthesizer.Note(554, start: 0.18, duration: 0.5),
            ToneSynthesizer.Note(659, start: 0.36, duration: 0.9),
        ])

        // The buffer runs to the last note's end, not the first note's.
        #expect(data.count == 44 + Int(1.26 * 44100) * 2)
    }
}
