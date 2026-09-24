import { createHash } from "node:crypto";
import { expect, test } from "@playwright/test";
import { sha256Hex } from "../src/sha256";

// Pure-TS SHA-256 (profile fingerprints, hashed keys). Runs in Node; no page needed.
test.describe("sha256", () => {
  test("FIPS 180-4 known answers", () => {
    expect(sha256Hex("")).toBe("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
    expect(sha256Hex("abc")).toBe("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    expect(sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")).toBe(
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    );
    expect(sha256Hex("a".repeat(1_000_000))).toBe("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0");
  });

  test("matches node:crypto across block boundaries and UTF-8", () => {
    const inputs = ["Duration (minutes)|text|step-client", "é · 字 · 🙂", ...[55, 56, 63, 64, 65, 119, 120, 128].map((n) => "x".repeat(n))];
    for (const s of inputs) expect(sha256Hex(s)).toBe(createHash("sha256").update(s, "utf8").digest("hex"));
  });
});
