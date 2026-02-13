package storage

import (
	"bytes"
	"context"
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
	"time"

	appconfig "baxter/internal/config"

	"github.com/aws/aws-sdk-go-v2/feature/s3/transfermanager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

type fakeUploader struct {
	lastInput *transfermanager.UploadObjectInput
	err       error
}

func (f *fakeUploader) UploadObject(_ context.Context, input *transfermanager.UploadObjectInput, _ ...func(*transfermanager.Options)) (*transfermanager.UploadObjectOutput, error) {
	f.lastInput = input
	if f.err != nil {
		return nil, f.err
	}
	return &transfermanager.UploadObjectOutput{}, nil
}

type fakeS3API struct {
	getFn    func(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	deleteFn func(ctx context.Context, params *s3.DeleteObjectInput, optFns ...func(*s3.Options)) (*s3.DeleteObjectOutput, error)
	listFn   func(ctx context.Context, params *s3.ListObjectsV2Input, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
}

func (f *fakeS3API) GetObject(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
	if f.getFn == nil {
		return nil, errors.New("unexpected get object call")
	}
	return f.getFn(ctx, params, optFns...)
}

func (f *fakeS3API) DeleteObject(ctx context.Context, params *s3.DeleteObjectInput, optFns ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
	if f.deleteFn == nil {
		return nil, errors.New("unexpected delete object call")
	}
	return f.deleteFn(ctx, params, optFns...)
}

func (f *fakeS3API) ListObjectsV2(ctx context.Context, params *s3.ListObjectsV2Input, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
	if f.listFn == nil {
		return nil, errors.New("unexpected list objects call")
	}
	return f.listFn(ctx, params, optFns...)
}

type paginatorStep struct {
	page           *s3.ListObjectsV2Output
	err            error
	waitForContext bool
}

type fakePaginator struct {
	steps []paginatorStep
	index int
}

func (p *fakePaginator) HasMorePages() bool {
	return p.index < len(p.steps)
}

func (p *fakePaginator) NextPage(ctx context.Context, _ ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
	if p.index >= len(p.steps) {
		return nil, errors.New("no more pages")
	}
	step := p.steps[p.index]
	p.index++
	if step.waitForContext {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	if step.err != nil {
		return nil, step.err
	}
	return step.page, nil
}

type errReadCloser struct{}

func (errReadCloser) Read(_ []byte) (int, error) { return 0, errors.New("read failure") }
func (errReadCloser) Close() error               { return nil }

func TestAWSListObjectsV2PaginatorNilInner(t *testing.T) {
	p := &awsListObjectsV2Paginator{}
	if p.HasMorePages() {
		t.Fatal("expected no pages when paginator is nil")
	}
	if _, err := p.NextPage(context.Background()); err == nil || !strings.Contains(err.Error(), "s3 paginator is not configured") {
		t.Fatalf("expected nil paginator error, got: %v", err)
	}
}

func TestNewFromConfigReturnsLocalClientWhenBucketEmpty(t *testing.T) {
	store, err := NewFromConfig(appconfig.S3Config{}, t.TempDir())
	if err != nil {
		t.Fatalf("new from config: %v", err)
	}
	if _, ok := store.(*LocalClient); !ok {
		t.Fatalf("expected LocalClient, got %T", store)
	}
}

func TestNewS3ClientValidationErrors(t *testing.T) {
	_, err := NewS3Client(appconfig.S3Config{
		Region: "us-west-2",
	})
	if err == nil || !strings.Contains(err.Error(), "s3 bucket is required") {
		t.Fatalf("expected missing bucket error, got: %v", err)
	}

	_, err = NewS3Client(appconfig.S3Config{
		Bucket: "backups",
	})
	if err == nil || !strings.Contains(err.Error(), "s3 region is required") {
		t.Fatalf("expected missing region error, got: %v", err)
	}

	_, err = NewS3Client(appconfig.S3Config{
		Bucket:   "backups",
		Region:   "us-west-2",
		Endpoint: "://bad",
	})
	if err == nil || !strings.Contains(err.Error(), "valid http(s) URL") {
		t.Fatalf("expected malformed endpoint error, got: %v", err)
	}

	_, err = NewS3Client(appconfig.S3Config{
		Bucket:   "backups",
		Region:   "us-west-2",
		Endpoint: "ftp://example.com",
	})
	if err == nil || !strings.Contains(err.Error(), "must use http or https") {
		t.Fatalf("expected endpoint scheme error, got: %v", err)
	}
}

func TestNormalizePrefix(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    string
		wantErr bool
	}{
		{name: "empty", input: "", want: ""},
		{name: "adds trailing slash", input: "baxter", want: "baxter/"},
		{name: "normalizes slashes", input: "baxter\\nested", want: "baxter/nested/"},
		{name: "collapses duplicate separators", input: "baxter//nested///", want: "baxter/nested/"},
		{name: "rejects absolute", input: "/baxter", wantErr: true},
		{name: "rejects parent traversal", input: "../baxter", wantErr: true},
		{name: "rejects nested traversal", input: "safe/../baxter", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := normalizePrefix(tt.input)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error for %q", tt.input)
				}
				return
			}
			if err != nil {
				t.Fatalf("normalize prefix failed: %v", err)
			}
			if got != tt.want {
				t.Fatalf("prefix mismatch: got %q want %q", got, tt.want)
			}
		})
	}
}

func TestS3PrefixedKeyValidation(t *testing.T) {
	c := &S3Client{prefix: "baxter/"}

	key, err := c.prefixedKey("folder/file")
	if err != nil {
		t.Fatalf("valid key rejected: %v", err)
	}
	if key != "baxter/folder/file" {
		t.Fatalf("prefixed key mismatch: got %q", key)
	}

	badKeys := []string{"", "   ", "/abs", "../escape", "safe/../escape", "./start", "nested//empty"}
	for _, bad := range badKeys {
		if _, err := c.prefixedKey(bad); err == nil {
			t.Fatalf("expected invalid key error for %q", bad)
		}
	}
}

func TestS3PutObjectSuccess(t *testing.T) {
	uploader := &fakeUploader{}
	c := &S3Client{
		uploader: uploader,
		bucket:   "bucket",
		prefix:   "baxter/",
	}

	if err := c.PutObject("folder/file", []byte("payload")); err != nil {
		t.Fatalf("put object failed: %v", err)
	}
	if uploader.lastInput == nil {
		t.Fatal("expected upload input to be captured")
	}
	if got := *uploader.lastInput.Bucket; got != "bucket" {
		t.Fatalf("bucket mismatch: got %q", got)
	}
	if got := *uploader.lastInput.Key; got != "baxter/folder/file" {
		t.Fatalf("key mismatch: got %q", got)
	}
	if got := *uploader.lastInput.ContentLength; got != int64(len("payload")) {
		t.Fatalf("content length mismatch: got %d", got)
	}

	buf := new(bytes.Buffer)
	if _, err := buf.ReadFrom(uploader.lastInput.Body); err != nil {
		t.Fatalf("read upload body: %v", err)
	}
	if got := buf.String(); got != "payload" {
		t.Fatalf("body mismatch: got %q", got)
	}
}

func TestS3PutObjectErrors(t *testing.T) {
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
	}
	if err := c.PutObject("key", []byte("x")); err == nil || !strings.Contains(err.Error(), "s3 uploader is not configured") {
		t.Fatalf("expected missing uploader error, got: %v", err)
	}

	c.uploader = &fakeUploader{err: errors.New("boom")}
	if err := c.PutObject("bad/../key", []byte("x")); err == nil || !strings.Contains(err.Error(), "invalid object key") {
		t.Fatalf("expected key validation error, got: %v", err)
	}

	if err := c.PutObject("key", []byte("x")); err == nil || !strings.Contains(err.Error(), "put object: boom") {
		t.Fatalf("expected wrapped upload error, got: %v", err)
	}
}

func TestS3GetObjectSuccess(t *testing.T) {
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
		api: &fakeS3API{
			getFn: func(_ context.Context, input *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
				if got := *input.Key; got != "baxter/key" {
					t.Fatalf("expected prefixed key, got %q", got)
				}
				return &s3.GetObjectOutput{
					Body: io.NopCloser(strings.NewReader("payload")),
				}, nil
			},
		},
	}

	got, err := c.GetObject("key")
	if err != nil {
		t.Fatalf("get object failed: %v", err)
	}
	if string(got) != "payload" {
		t.Fatalf("payload mismatch: got %q", string(got))
	}
}

func TestS3GetObjectErrors(t *testing.T) {
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
	}
	if _, err := c.GetObject("key"); err == nil || !strings.Contains(err.Error(), "s3 api client is not configured") {
		t.Fatalf("expected missing api client error, got: %v", err)
	}

	c.api = &fakeS3API{
		getFn: func(_ context.Context, _ *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
			return nil, errors.New("boom")
		},
	}
	if _, err := c.GetObject("key"); err == nil || !strings.Contains(err.Error(), "get object: boom") {
		t.Fatalf("expected wrapped get error, got: %v", err)
	}

	c.api = &fakeS3API{
		getFn: func(_ context.Context, _ *s3.GetObjectInput, _ ...func(*s3.Options)) (*s3.GetObjectOutput, error) {
			return &s3.GetObjectOutput{Body: errReadCloser{}}, nil
		},
	}
	if _, err := c.GetObject("key"); err == nil || !strings.Contains(err.Error(), "read object body: read failure") {
		t.Fatalf("expected body read error, got: %v", err)
	}
}

func TestS3DeleteObjectSuccessAndErrors(t *testing.T) {
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
	}
	if err := c.DeleteObject("key"); err == nil || !strings.Contains(err.Error(), "s3 api client is not configured") {
		t.Fatalf("expected missing api error, got: %v", err)
	}

	c.api = &fakeS3API{
		deleteFn: func(_ context.Context, input *s3.DeleteObjectInput, _ ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
			if got := *input.Key; got != "baxter/path/item" {
				t.Fatalf("delete key mismatch: got %q", got)
			}
			return &s3.DeleteObjectOutput{}, nil
		},
	}
	if err := c.DeleteObject("path/item"); err != nil {
		t.Fatalf("delete object failed: %v", err)
	}

	if err := c.DeleteObject("bad/../item"); err == nil || !strings.Contains(err.Error(), "invalid object key") {
		t.Fatalf("expected invalid key error, got: %v", err)
	}

	c.api = &fakeS3API{
		deleteFn: func(_ context.Context, _ *s3.DeleteObjectInput, _ ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
			return nil, errors.New("boom")
		},
	}
	if err := c.DeleteObject("key"); err == nil || !strings.Contains(err.Error(), "delete object: boom") {
		t.Fatalf("expected wrapped delete error, got: %v", err)
	}
}

func TestS3DeleteObjectTimeout(t *testing.T) {
	c := &S3Client{
		bucket:        "bucket",
		prefix:        "baxter/",
		deleteTimeout: 20 * time.Millisecond,
		api: &fakeS3API{
			deleteFn: func(ctx context.Context, _ *s3.DeleteObjectInput, _ ...func(*s3.Options)) (*s3.DeleteObjectOutput, error) {
				<-ctx.Done()
				return nil, ctx.Err()
			},
		},
	}

	err := c.DeleteObject("key")
	if err == nil {
		t.Fatal("expected delete timeout error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded, got: %v", err)
	}
}

func TestS3ListKeysSuccess(t *testing.T) {
	paginator := &fakePaginator{
		steps: []paginatorStep{
			{
				page: &s3.ListObjectsV2Output{
					Contents: []types.Object{
						{Key: nil},
						{Key: strPtr("baxter/")},
						{Key: strPtr("other/file")},
						{Key: strPtr("baxter/z-last")},
					},
				},
			},
			{
				page: &s3.ListObjectsV2Output{
					Contents: []types.Object{
						{Key: strPtr("baxter/a-first")},
						{Key: strPtr("baxter/nested\\item")},
					},
				},
			},
		},
	}

	var capturedInput *s3.ListObjectsV2Input
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
		api: &fakeS3API{listFn: func(_ context.Context, _ *s3.ListObjectsV2Input, _ ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
			return nil, nil
		}},
		newListObjectsV2Paginator: func(_ s3.ListObjectsV2APIClient, input *s3.ListObjectsV2Input) listObjectsV2Paginator {
			capturedInput = input
			return paginator
		},
	}

	keys, err := c.ListKeys()
	if err != nil {
		t.Fatalf("list keys failed: %v", err)
	}
	want := []string{"a-first", "nested/item", "z-last"}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("keys mismatch: got %v want %v", keys, want)
	}
	if capturedInput == nil {
		t.Fatal("expected paginator input to be captured")
	}
	if got := *capturedInput.Bucket; got != "bucket" {
		t.Fatalf("bucket mismatch: got %q", got)
	}
	if capturedInput.Prefix == nil || *capturedInput.Prefix != "baxter/" {
		t.Fatalf("prefix mismatch: got %#v", capturedInput.Prefix)
	}
}

func TestS3ListKeysErrors(t *testing.T) {
	c := &S3Client{
		bucket: "bucket",
		prefix: "baxter/",
	}
	if _, err := c.ListKeys(); err == nil || !strings.Contains(err.Error(), "s3 api client is not configured") {
		t.Fatalf("expected missing api client error, got: %v", err)
	}

	c.api = &fakeS3API{}
	if _, err := c.ListKeys(); err == nil || !strings.Contains(err.Error(), "s3 paginator factory is not configured") {
		t.Fatalf("expected missing paginator factory error, got: %v", err)
	}

	c.newListObjectsV2Paginator = func(_ s3.ListObjectsV2APIClient, _ *s3.ListObjectsV2Input) listObjectsV2Paginator {
		return nil
	}
	if _, err := c.ListKeys(); err == nil || !strings.Contains(err.Error(), "s3 paginator is not configured") {
		t.Fatalf("expected missing paginator error, got: %v", err)
	}

	c.newListObjectsV2Paginator = func(_ s3.ListObjectsV2APIClient, _ *s3.ListObjectsV2Input) listObjectsV2Paginator {
		return &fakePaginator{steps: []paginatorStep{{err: errors.New("boom")}}}
	}
	if _, err := c.ListKeys(); err == nil || !strings.Contains(err.Error(), "list objects: boom") {
		t.Fatalf("expected wrapped list error, got: %v", err)
	}
}

func TestS3ListKeysTimeout(t *testing.T) {
	c := &S3Client{
		bucket:          "bucket",
		prefix:          "baxter/",
		listPageTimeout: 20 * time.Millisecond,
		api:             &fakeS3API{},
		newListObjectsV2Paginator: func(_ s3.ListObjectsV2APIClient, _ *s3.ListObjectsV2Input) listObjectsV2Paginator {
			return &fakePaginator{steps: []paginatorStep{{waitForContext: true}}}
		},
	}

	_, err := c.ListKeys()
	if err == nil {
		t.Fatal("expected list timeout error")
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("expected deadline exceeded, got: %v", err)
	}
}

func strPtr(v string) *string { return &v }
