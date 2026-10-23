package service

import (
	"path/filepath"
	"testing"

	"petserver/internal/storage"
)

func newAccessTestService(t *testing.T) *AccessService {
	t.Helper()
	store, err := storage.NewActivationStore(filepath.Join(t.TempDir(), "codes.json"))
	if err != nil {
		t.Fatal(err)
	}
	return NewAccessService(store)
}

// Generate stamps the requested per-code image quota onto every produced code, and ImageQuota reads
// it back through the same normalization the verify path uses (case and separators are ignored).
func TestAccessGenerateStoresImageQuota(t *testing.T) {
	svc := newAccessTestService(t)
	codes, err := svc.Generate(2, 3, 0, 7, "shop")
	if err != nil {
		t.Fatal(err)
	}
	if len(codes) != 2 {
		t.Fatalf("generated %d codes, want 2", len(codes))
	}
	for _, c := range codes {
		if got := svc.ImageQuota(c); got != 7 {
			t.Fatalf("ImageQuota(%s) = %d, want 7", c, got)
		}
		// A differently-formatted but equivalent input resolves to the same stored code.
		if got := svc.ImageQuota(normalizeCode(c)); got != 7 {
			t.Fatalf("ImageQuota(normalized %s) = %d, want 7", c, got)
		}
	}
	// Unknown or empty codes have no quota (default 0 = not granted).
	if got := svc.ImageQuota("ZZZZ-ZZZZ-ZZZZ"); got != 0 {
		t.Fatalf("ImageQuota on unknown code = %d, want 0", got)
	}
	if got := svc.ImageQuota(""); got != 0 {
		t.Fatalf("ImageQuota on empty code = %d, want 0", got)
	}
}

// SetImageQuota overwrites a code's total (raise or lower), normalizes the code argument, clamps
// negatives to zero, and reports whether the code exists.
func TestAccessSetImageQuota(t *testing.T) {
	svc := newAccessTestService(t)
	codes, err := svc.Generate(1, 1, 0, 0, "")
	if err != nil {
		t.Fatal(err)
	}
	code := codes[0]

	// Default-granted zero, then raised by an admin edit.
	if svc.ImageQuota(code) != 0 {
		t.Fatalf("new code should default to 0 quota")
	}
	found, err := svc.SetImageQuota(code, 5)
	if err != nil || !found {
		t.Fatalf("SetImageQuota found=%v err=%v", found, err)
	}
	if svc.ImageQuota(code) != 5 {
		t.Fatalf("quota after raise = %d, want 5", svc.ImageQuota(code))
	}
	// Lowering takes effect immediately for future admissions.
	if found, err = svc.SetImageQuota(code, 1); err != nil || !found {
		t.Fatalf("lower SetImageQuota found=%v err=%v", found, err)
	}
	if svc.ImageQuota(code) != 1 {
		t.Fatalf("quota after lower = %d, want 1", svc.ImageQuota(code))
	}
	// Negative input is clamped to zero (revoke), never stored as a negative budget.
	if _, err = svc.SetImageQuota(code, -3); err != nil {
		t.Fatal(err)
	}
	if svc.ImageQuota(code) != 0 {
		t.Fatalf("negative quota should clamp to 0, got %d", svc.ImageQuota(code))
	}
	// Missing code reports not-found without error.
	if found, err = svc.SetImageQuota("QQQQ-QQQQ-QQQQ", 3); err != nil || found {
		t.Fatalf("SetImageQuota on missing code found=%v err=%v", found, err)
	}
}
