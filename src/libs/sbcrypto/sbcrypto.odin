package sbcrypto

import "core:crypto"
import "core:crypto/aes"
import "core:crypto/sha2"
import "core:encoding/base64"
import "core:strings"

// ============================================================================
// AES-256-GCM secret-string encryption, keyed off a per-machine seed.
//
// On-disk format for an encrypted value:
//
//   base64( nonce[12] || ciphertext || tag[16] )
//
// GCM is authenticated, so a value that has been tampered with — or one
// copied from another machine — fails to open rather than decrypting to
// garbage. Callers get (value, false) and can drop the stored secret.
//
// WHAT THIS DOES AND DOESN'T PROTECT AGAINST
//
// The key is derived from identifiers this machine can read, so anything
// running as you can derive it too. What it buys:
//
//   * settings.json no longer shows a password to anyone reading over
//     your shoulder, screen-sharing, or opening it to change a setting
//   * a config file copied to another machine, synced to a cloud drive,
//     posted in a bug report, or committed by accident is inert
//
// What it does not buy: protection from malware already running under
// your account. For that you want the OS keychain, which is a different
// (and much larger) integration.
//
// Vendored from intralabels' src/libs/sbcrypto, which is Linux-only.
// This copy adds a Windows machine seed — see machine_seed below.
// ============================================================================

@(private = "file") GCM_NONCE_SIZE :: aes.GCM_IV_SIZE
@(private = "file") GCM_TAG_SIZE :: aes.GCM_TAG_SIZE
@(private = "file") AES_KEY_SIZE :: aes.KEY_SIZE_256

// Domain separator. Changing it invalidates every previously stored
// value on purpose — bump it if the format ever changes.
@(private = "file") KEY_SALT :: "er-boss-checklist.v1"

@(private = "file")
derive_key :: proc(out: ^[AES_KEY_SIZE]byte) -> bool {
	seed := machine_seed(context.temp_allocator)
	if len(seed) == 0 {
		// Refuse rather than silently falling back to a constant key,
		// which would be the same on every install and would make the
		// ciphertext portable — exactly what this is meant to prevent.
		return false
	}

	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)string(KEY_SALT))
	sha2.update(&ctx, transmute([]byte)seed)
	sha2.final(&ctx, out[:])
	return true
}

// Returns "" when no secret could be produced (no usable machine seed).
// Callers should treat that as "don't store this".
encrypt_string :: proc(plaintext: string, allocator := context.allocator) -> string {
	if len(plaintext) == 0 do return ""

	key: [AES_KEY_SIZE]byte
	if !derive_key(&key) do return ""

	nonce: [GCM_NONCE_SIZE]byte
	crypto.rand_bytes(nonce[:])

	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key[:])
	defer aes.reset_gcm(&ctx)

	pt := transmute([]byte)plaintext
	ciphertext := make([]byte, len(pt), context.temp_allocator)
	tag: [GCM_TAG_SIZE]byte

	aes.seal_gcm(&ctx, ciphertext, tag[:], nonce[:], nil, pt)

	blob := make([]byte, GCM_NONCE_SIZE + len(ciphertext) + GCM_TAG_SIZE, context.temp_allocator)
	copy(blob[0:], nonce[:])
	copy(blob[GCM_NONCE_SIZE:], ciphertext)
	copy(blob[GCM_NONCE_SIZE + len(ciphertext):], tag[:])

	return base64.encode(blob, allocator = allocator)
}

// Returns ok = false for anything that isn't a value this machine
// encrypted: corruption, truncation, a different machine's file, or a
// plaintext password left over from an older version.
decrypt_string :: proc(b64: string, allocator := context.allocator) -> (string, bool) {
	if len(b64) == 0 do return "", true

	blob, derr := base64.decode(b64, allocator = context.temp_allocator)
	if derr != nil do return "", false
	if len(blob) < GCM_NONCE_SIZE + GCM_TAG_SIZE do return "", false

	key: [AES_KEY_SIZE]byte
	if !derive_key(&key) do return "", false

	nonce := blob[:GCM_NONCE_SIZE]
	tag := blob[len(blob) - GCM_TAG_SIZE:]
	ct := blob[GCM_NONCE_SIZE:len(blob) - GCM_TAG_SIZE]

	plaintext := make([]byte, len(ct), allocator)

	ctx: aes.Context_GCM
	aes.init_gcm(&ctx, key[:])
	defer aes.reset_gcm(&ctx)

	if !aes.open_gcm(&ctx, plaintext, nonce, nil, ct, tag) {
		delete(plaintext, allocator)
		return "", false
	}

	out := strings.clone_from_bytes(plaintext, allocator)
	delete(plaintext, allocator)
	return out, true
}

// True when this machine can produce a key at all. The UI uses it to
// avoid offering to remember a password it can't protect.
available :: proc() -> bool {
	key: [AES_KEY_SIZE]byte
	return derive_key(&key)
}
