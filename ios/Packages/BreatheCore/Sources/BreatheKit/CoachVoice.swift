import Foundation

/// Speaks the coach's replies aloud, one sentence at a time.
///
/// The seam pattern `StoreFront` and `HealthStore` set: the model talks to
/// this protocol, and which synthesiser sits behind it is the composition
/// root's choice. Deliberately sentence-oriented — `speak` takes one finished
/// sentence, not a growing buffer — so a future server-side neural voice (a
/// provider call returning audio per sentence) can slot in behind the same
/// three members without touching `CoachChatModel` or the view.
///
/// Implementations queue: a second `speak` while the first sentence is still
/// playing appends rather than interrupts, which is what lets the model hand
/// sentences over as they complete while the reply is still streaming.
@MainActor
public protocol CoachVoice: AnyObject {
    /// Queues one sentence to be spoken after whatever is already playing.
    func speak(_ sentence: String)

    /// Stops mid-word and empties the queue. Called on send and on the view
    /// disappearing — a voice reading a reply nobody is looking at, or one
    /// the person has already moved past, is noise.
    func stop()
}
