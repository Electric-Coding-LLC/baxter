package storage

type ObjectStore interface {
	PutObject(key string, data []byte) error
	GetObject(key string) ([]byte, error)
	DeleteObject(key string) error
	ListKeys() ([]string, error)
}
