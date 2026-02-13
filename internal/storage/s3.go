package storage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	appconfig "baxter/internal/config"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/transfermanager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	defaultUploadPartSize    int64 = 8 * 1024 * 1024
	defaultUploadConcurrency       = 4
	defaultRetryMaxAttempts        = 2
	defaultDeleteTimeout           = 30 * time.Second
	defaultListPageTimeout         = 30 * time.Second
)

type s3API interface {
	GetObject(ctx context.Context, params *s3.GetObjectInput, optFns ...func(*s3.Options)) (*s3.GetObjectOutput, error)
	DeleteObject(ctx context.Context, params *s3.DeleteObjectInput, optFns ...func(*s3.Options)) (*s3.DeleteObjectOutput, error)
	ListObjectsV2(ctx context.Context, params *s3.ListObjectsV2Input, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
}

type s3Uploader interface {
	UploadObject(ctx context.Context, input *transfermanager.UploadObjectInput, opts ...func(*transfermanager.Options)) (*transfermanager.UploadObjectOutput, error)
}

type listObjectsV2Paginator interface {
	HasMorePages() bool
	NextPage(ctx context.Context, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error)
}

type listObjectsV2PaginatorFactory func(client s3.ListObjectsV2APIClient, params *s3.ListObjectsV2Input) listObjectsV2Paginator

type awsListObjectsV2Paginator struct {
	inner *s3.ListObjectsV2Paginator
}

func (p *awsListObjectsV2Paginator) HasMorePages() bool {
	return p.inner != nil && p.inner.HasMorePages()
}

func (p *awsListObjectsV2Paginator) NextPage(ctx context.Context, optFns ...func(*s3.Options)) (*s3.ListObjectsV2Output, error) {
	if p.inner == nil {
		return nil, errors.New("s3 paginator is not configured")
	}
	return p.inner.NextPage(ctx, optFns...)
}

type S3Client struct {
	api                       s3API
	uploader                  s3Uploader
	newListObjectsV2Paginator listObjectsV2PaginatorFactory
	bucket                    string
	prefix                    string
	deleteTimeout             time.Duration
	listPageTimeout           time.Duration
}

func NewFromConfig(cfg appconfig.S3Config, localRootDir string) (ObjectStore, error) {
	if cfg.Bucket == "" {
		return NewLocalClient(localRootDir), nil
	}
	return NewS3Client(cfg)
}

func NewS3Client(cfg appconfig.S3Config) (*S3Client, error) {
	bucket := strings.TrimSpace(cfg.Bucket)
	if bucket == "" {
		return nil, errors.New("s3 bucket is required")
	}
	region := strings.TrimSpace(cfg.Region)
	if region == "" {
		return nil, errors.New("s3 region is required")
	}
	endpoint := strings.TrimSpace(cfg.Endpoint)
	if endpoint != "" {
		if err := validateEndpoint(endpoint); err != nil {
			return nil, err
		}
	}
	prefix, err := normalizePrefix(cfg.Prefix)
	if err != nil {
		return nil, err
	}

	loadOpts := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(region),
		awsconfig.WithRetryMode(aws.RetryModeStandard),
		awsconfig.WithRetryMaxAttempts(defaultRetryMaxAttempts),
	}

	if endpoint != "" {
		resolver := aws.EndpointResolverWithOptionsFunc(func(service, region string, options ...interface{}) (aws.Endpoint, error) {
			return aws.Endpoint{URL: endpoint, Source: aws.EndpointSourceCustom}, nil
		})
		loadOpts = append(loadOpts, awsconfig.WithEndpointResolverWithOptions(resolver))
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(), loadOpts...)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	s3Opts := func(o *s3.Options) {
		if endpoint != "" {
			o.UsePathStyle = true
		}
	}

	client := s3.NewFromConfig(awsCfg, s3Opts)
	tm := transfermanager.New(client, func(o *transfermanager.Options) {
		o.PartSizeBytes = defaultUploadPartSize
		o.Concurrency = defaultUploadConcurrency
	})

	return &S3Client{
		api:      client,
		uploader: tm,
		newListObjectsV2Paginator: func(client s3.ListObjectsV2APIClient, params *s3.ListObjectsV2Input) listObjectsV2Paginator {
			return &awsListObjectsV2Paginator{inner: s3.NewListObjectsV2Paginator(client, params)}
		},
		bucket:          bucket,
		prefix:          prefix,
		deleteTimeout:   defaultDeleteTimeout,
		listPageTimeout: defaultListPageTimeout,
	}, nil
}

func (c *S3Client) PutObject(key string, data []byte) error {
	if c == nil {
		return errors.New("s3 client is not configured")
	}
	if c.uploader == nil {
		return errors.New("s3 uploader is not configured")
	}
	if c.bucket == "" {
		return errors.New("s3 bucket is not configured")
	}

	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return err
	}

	contentLength := int64(len(data))
	_, err = c.uploader.UploadObject(context.Background(), &transfermanager.UploadObjectInput{
		Bucket:        &c.bucket,
		Key:           &objectKey,
		Body:          bytes.NewReader(data),
		ContentLength: &contentLength,
	})
	if err != nil {
		return fmt.Errorf("put object: %w", err)
	}
	return nil
}

func (c *S3Client) GetObject(key string) ([]byte, error) {
	if c == nil {
		return nil, errors.New("s3 client is not configured")
	}
	if c.api == nil {
		return nil, errors.New("s3 api client is not configured")
	}
	if c.bucket == "" {
		return nil, errors.New("s3 bucket is not configured")
	}

	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return nil, err
	}

	out, err := c.api.GetObject(context.Background(), &s3.GetObjectInput{
		Bucket: &c.bucket,
		Key:    &objectKey,
	})
	if err != nil {
		return nil, fmt.Errorf("get object: %w", err)
	}
	defer out.Body.Close()

	buf := new(bytes.Buffer)
	if _, err := buf.ReadFrom(out.Body); err != nil {
		return nil, fmt.Errorf("read object body: %w", err)
	}
	return buf.Bytes(), nil
}

func (c *S3Client) DeleteObject(key string) error {
	if c == nil {
		return errors.New("s3 client is not configured")
	}
	if c.api == nil {
		return errors.New("s3 api client is not configured")
	}
	if c.bucket == "" {
		return errors.New("s3 bucket is not configured")
	}

	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return err
	}

	ctx := context.Background()
	cancel := func() {}
	if c.deleteTimeout > 0 {
		ctx, cancel = context.WithTimeout(ctx, c.deleteTimeout)
	}
	defer cancel()

	_, err = c.api.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: &c.bucket,
		Key:    &objectKey,
	})
	if err != nil {
		return fmt.Errorf("delete object: %w", err)
	}
	return nil
}

func (c *S3Client) ListKeys() ([]string, error) {
	if c == nil {
		return nil, errors.New("s3 client is not configured")
	}
	if c.api == nil {
		return nil, errors.New("s3 api client is not configured")
	}
	if c.newListObjectsV2Paginator == nil {
		return nil, errors.New("s3 paginator factory is not configured")
	}
	if c.bucket == "" {
		return nil, errors.New("s3 bucket is not configured")
	}

	keys := make([]string, 0)
	paginator := c.newListObjectsV2Paginator(c.api, &s3.ListObjectsV2Input{
		Bucket: &c.bucket,
		Prefix: aws.String(c.prefix),
	})
	if paginator == nil {
		return nil, errors.New("s3 paginator is not configured")
	}

	for paginator.HasMorePages() {
		ctx := context.Background()
		cancel := func() {}
		if c.listPageTimeout > 0 {
			ctx, cancel = context.WithTimeout(ctx, c.listPageTimeout)
		}
		page, err := paginator.NextPage(ctx)
		cancel()
		if err != nil {
			return nil, fmt.Errorf("list objects: %w", err)
		}
		for _, obj := range page.Contents {
			if obj.Key == nil {
				continue
			}
			fullKey := strings.ReplaceAll(*obj.Key, "\\", "/")
			trimmed := fullKey
			if c.prefix != "" {
				if !strings.HasPrefix(fullKey, c.prefix) {
					continue
				}
				trimmed = strings.TrimPrefix(fullKey, c.prefix)
			}
			normalized, err := normalizeObjectKey(trimmed)
			if err != nil {
				continue
			}
			keys = append(keys, normalized)
		}
	}

	sort.Strings(keys)
	return keys, nil
}

func (c *S3Client) prefixedKey(key string) (string, error) {
	cleaned, err := normalizeObjectKey(key)
	if err != nil {
		return "", err
	}
	return c.prefix + cleaned, nil
}

func normalizeObjectKey(key string) (string, error) {
	normalized := strings.TrimSpace(strings.ReplaceAll(key, "\\", "/"))
	if normalized == "" {
		return "", errors.New("object key cannot be empty")
	}
	if strings.HasPrefix(normalized, "/") {
		return "", errors.New("invalid object key")
	}

	parts := strings.Split(normalized, "/")
	cleanParts := make([]string, 0, len(parts))
	for _, part := range parts {
		if part == "" || part == "." || part == ".." {
			return "", errors.New("invalid object key")
		}
		cleanParts = append(cleanParts, part)
	}
	if len(cleanParts) == 0 {
		return "", errors.New("invalid object key")
	}
	return strings.Join(cleanParts, "/"), nil
}

func normalizePrefix(prefix string) (string, error) {
	normalized := strings.TrimSpace(strings.ReplaceAll(prefix, "\\", "/"))
	if normalized == "" {
		return "", nil
	}
	if strings.HasPrefix(normalized, "/") {
		return "", errors.New("invalid s3 prefix")
	}

	parts := strings.Split(normalized, "/")
	cleanParts := make([]string, 0, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if part == "." || part == ".." {
			return "", errors.New("invalid s3 prefix")
		}
		cleanParts = append(cleanParts, part)
	}
	if len(cleanParts) == 0 {
		return "", errors.New("invalid s3 prefix")
	}
	return strings.Join(cleanParts, "/") + "/", nil
}

func validateEndpoint(endpoint string) error {
	parsed, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil || parsed == nil || parsed.Host == "" {
		return errors.New("s3 endpoint must be a valid http(s) URL")
	}
	scheme := strings.ToLower(parsed.Scheme)
	if scheme != "http" && scheme != "https" {
		return errors.New("s3 endpoint must use http or https")
	}
	return nil
}
