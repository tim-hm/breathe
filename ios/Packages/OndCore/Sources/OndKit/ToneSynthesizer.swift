import Foundation

/// Builds the session's cue tones in memory, as WAV data `AVAudioPlayer` can
/// open directly.
///
/// Synthesised rather than shipped as assets: four sine tones and a closing
/// triad are a few lines of arithmetic, and generating them keeps the app free
/// of sample files whose licence, loudness, and tuning would all need managing.
///
/// In `OndKit` rather than beside the audio player it feeds, for one
/// reason: it is the only code here where a wrong constant produces silence or
/// noise instead of a compile error, and the app target has no test bundle.
/// Playback stays in the app, where `AVFoundation` belongs.
public enum ToneSynthesizer {
    /// One sine tone, placed in the buffer.
    public struct Note: Sendable {
        let frequency: Double
        /// Offset from the start of the buffer, in seconds.
        let start: Double
        let duration: Double

        public init(_ frequency: Double, start: Double = 0, duration: Double) {
            self.frequency = frequency
            self.start = start
            self.duration = duration
        }
    }

    private static let sampleRate: Double = 44100
    /// Well below full scale. These play over whatever else is going on, and a
    /// breathing cue that startles has failed at its job.
    private static let amplitude: Double = 0.32
    /// Long enough to keep the onset from clicking, short enough to still read
    /// as a cue landing on the beat.
    private static let attack: Double = 0.02

    /// Mono 16-bit PCM at 44.1 kHz — the format every Apple audio path decodes
    /// without resampling.
    public static func wav(_ notes: [Note]) -> Data {
        let span = notes.map { $0.start + $0.duration }.max() ?? 0
        var samples = [Int16](repeating: 0, count: Int(span * sampleRate))

        for note in notes {
            let offset = Int(note.start * sampleRate)
            let length = Int(note.duration * sampleRate)

            for frame in 0 ..< length where offset + frame < samples.count {
                let time = Double(frame) / sampleRate
                let value = sin(2 * .pi * note.frequency * time)
                    * envelope(at: time, of: note.duration)
                    * amplitude
                // Summed rather than assigned so overlapping notes can chord,
                // and clamped so a chord that peaks together cannot wrap.
                samples[offset + frame] = samples[offset + frame]
                    .addingReportingOverflow(Int16(value * Double(Int16.max)))
                    .partialValue
            }
        }

        return container(samples)
    }

    /// A stretch of pure silence, in the same format as the tones above.
    ///
    /// This is what holds a backgrounded session's place on the phone. iOS keeps
    /// an app with the `audio` background mode scheduled only while it is
    /// actually playing something, and the cue tones are tenths of a second
    /// inside phases that run for four to eleven; a session left to them alone is
    /// suspended in the first gap. Looped underneath, this makes those gaps the
    /// inside of one continuous playback rather than the end of it.
    ///
    /// - Parameter seconds: how long a loop to build. Long enough not to restart
    ///   constantly, short enough to stay a rounding error in memory.
    public static func silence(seconds: Double) -> Data {
        container([Int16](repeating: 0, count: Int(seconds * sampleRate)))
    }

    /// Fade in, then decay to silence — a struck-bell shape. Both ends taper to
    /// zero, because a waveform cut mid-cycle is a click.
    private static func envelope(at time: Double, of duration: Double) -> Double {
        let rise = min(time / attack, 1)
        let fall = min((duration - time) / attack, 1)
        return rise * fall * exp(-3.5 * time / duration)
    }

    /// The 44-byte canonical WAV header, then the samples.
    private static func container(_ samples: [Int16]) -> Data {
        let bytesPerSample = 2
        let dataBytes = UInt32(samples.count * bytesPerSample)
        var data = Data(capacity: 44 + Int(dataBytes))

        data.append(ascii: "RIFF")
        data.append(littleEndian: UInt32(36) + dataBytes)
        data.append(ascii: "WAVE")

        data.append(ascii: "fmt ")
        data.append(littleEndian: UInt32(16)) // PCM header length
        data.append(littleEndian: UInt16(1)) // uncompressed PCM
        data.append(littleEndian: UInt16(1)) // mono
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: UInt32(sampleRate) * UInt32(bytesPerSample)) // bytes per second
        data.append(littleEndian: UInt16(bytesPerSample)) // frame alignment
        data.append(littleEndian: UInt16(16)) // bits per sample

        data.append(ascii: "data")
        data.append(littleEndian: dataBytes)
        // One copy rather than 130,000 two-byte appends: every Apple platform is
        // little-endian, so the array's memory is already the file's byte order.
        samples.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

        return data
    }
}

private extension Data {
    mutating func append(ascii text: String) {
        append(contentsOf: Array(text.utf8))
    }

    /// WAV is a little-endian format regardless of the host's byte order.
    ///
    /// `Swift.` qualified because `Data` has an instance method of the same name
    /// that shadows the global one inside this extension.
    mutating func append(littleEndian value: some FixedWidthInteger) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
