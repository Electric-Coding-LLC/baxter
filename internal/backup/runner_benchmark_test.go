package backup

import (
	"crypto/rand"
	"testing"

	"baxter/internal/crypto"
)

type discardStore struct{}

func (discardStore) PutObject(string, []byte) error { return nil }
func (discardStore) GetObject(string) ([]byte, error) {
	return nil, nil
}
func (discardStore) DeleteObject(string) error { return nil }
func (discardStore) ListKeys() ([]string, error) {
	return []string{}, nil
}

func BenchmarkUploadPipelineCompressionImpact(b *testing.B) {
	key := []byte("01234567890123456789012345678901")
	store := discardStore{}

	cases := []struct {
		name string
		data []byte
	}{
		{name: "compressible_8MiB", data: compressiblePayload(8 * 1024 * 1024)},
		{name: "compressible_32MiB", data: compressiblePayload(32 * 1024 * 1024)},
		{name: "incompressible_8MiB", data: incompressiblePayload(b, 8*1024*1024)},
		{name: "incompressible_32MiB", data: incompressiblePayload(b, 32*1024*1024)},
	}

	for _, tc := range cases {
		tc := tc
		b.Run(tc.name, func(b *testing.B) {
			b.ReportAllocs()
			b.SetBytes(int64(len(tc.data)))

			for i := 0; i < b.N; i++ {
				payload, err := crypto.EncryptBytes(key, tc.data)
				if err != nil {
					b.Fatalf("encrypt payload: %v", err)
				}
				if err := putObjectWithRetry(store, "bench-object", payload, 1); err != nil {
					b.Fatalf("put object: %v", err)
				}
			}
		})
	}
}

func compressiblePayload(size int) []byte {
	pattern := []byte("baxter-compressible-data-")
	data := make([]byte, size)
	for i := 0; i < size; i += len(pattern) {
		n := copy(data[i:], pattern)
		if n < len(pattern) {
			break
		}
	}
	return data
}

func incompressiblePayload(b *testing.B, size int) []byte {
	b.Helper()
	data := make([]byte, size)
	if _, err := rand.Read(data); err != nil {
		b.Fatalf("read random data for benchmark fixture: %v", err)
	}
	return data
}

func BenchmarkEncryptBytesV3MetadataOverhead(b *testing.B) {
	key := []byte("01234567890123456789012345678901")
	data := compressiblePayload(1024 * 1024)

	b.ReportAllocs()
	b.SetBytes(int64(len(data)))
	for i := 0; i < b.N; i++ {
		payload, err := crypto.EncryptBytes(key, data)
		if err != nil {
			b.Fatalf("encrypt payload: %v", err)
		}
		if len(payload) < 2 {
			b.Fatalf("payload missing version/compression metadata: len=%d", len(payload))
		}
		if payload[0] != 3 {
			b.Fatalf("unexpected payload version: %d", payload[0])
		}
	}
}
