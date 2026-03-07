///|
/// Hasher is a trait for computing rolling checksums over byte data.
/// Aligned with moonbitlang/x CryptoHasher but returns UInt for 32-bit checksums.
pub(open) trait Hasher {
  /// Returns the hash output size in bytes.
  size(Self) -> Int
  /// Resets the hasher to its initial state.
  reset(Self) -> Unit
  /// Feeds bytes into the running hash.
  update(Self, BytesView) -> Unit
  /// Returns the current checksum value.
  checksum(Self) -> UInt
}
