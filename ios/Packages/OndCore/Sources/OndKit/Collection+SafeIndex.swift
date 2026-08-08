public extension Collection {
    /// The element at `index`, or nil where it is out of bounds.
    ///
    /// For the places a table is indexed by something that came from somewhere
    /// else — a hint array against a stage's phases, a sign array against a
    /// cycle — where the shapes are checked but the check and the lookup sit far
    /// enough apart that the compiler cannot carry the guarantee between them.
    ///
    /// Not a licence to index carelessly: where a guarantee is local, say so
    /// with a plain subscript. This exists because the same
    /// `indices.contains(i) ? xs[i] : nil` was written four times while the
    /// figures were being drawn.
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
