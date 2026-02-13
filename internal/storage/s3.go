package storage

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	appconfig "baxter/internal/config"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/feature/s3/transfermanager"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

const (
	defaultUploadPartSize    int64 = 8 * 1024 * 1024
	defaultUploadConcurrency       = 4
)

type S3Client struct {
	client          *s3.Client
	transferManager *transfermanager.Client
	bucket          string
	prefix          string
}

func NewFromConfig(cfg appconfig.S3Config, localRootDir string) (ObjectStore, error) {
	if cfg.Bucket == "" {
		return NewLocalClient(localRootDir), nil
	}
	return NewS3Client(cfg)
}

func NewS3Client(cfg appconfig.S3Config) (*S3Client, error) {
	if cfg.Bucket == "" {
		return nil, errors.New("s3 bucket is required")
	}
	if cfg.Region == "" {
		return nil, errors.New("s3 region is required")
	}

	loadOpts := []func(*awsconfig.LoadOptions) error{
		awsconfig.WithRegion(cfg.Region),
	}

	if cfg.Endpoint != "" {
		resolver := aws.EndpointResolverWithOptionsFunc(func(service, region string, options ...interface{}) (aws.Endpoint, error) {
			return aws.Endpoint{URL: cfg.Endpoint, Source: aws.EndpointSourceCustom}, nil
		})
		loadOpts = append(loadOpts, awsconfig.WithEndpointResolverWithOptions(resolver))
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(context.Background(), loadOpts...)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	s3Opts := func(o *s3.Options) {
		if cfg.Endpoint != "" {
			o.UsePathStyle = true
		}
	}

	client := s3.NewFromConfig(awsCfg, s3Opts)
	tm := transfermanager.New(client, func(o *transfermanager.Options) {
		o.PartSizeBytes = defaultUploadPartSize
		o.Concurrency = defaultUploadConcurrency
	})

	return &S3Client{
		client:          client,
		transferManager: tm,
		bucket:          cfg.Bucket,
		prefix:          cfg.Prefix,
	}, nil
}

func (c *S3Client) PutObject(key string, data []byte) error {
	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return err
	}
	if c.transferManager == nil {
		return errors.New("s3 transfer manager is not configured")
	}

	contentLength := int64(len(data))
	_, err = c.transferManager.UploadObject(context.Background(), &transfermanager.UploadObjectInput{
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
	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return nil, err
	}

	out, err := c.client.GetObject(context.Background(), &s3.GetObjectInput{
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
	objectKey, err := c.prefixedKey(key)
	if err != nil {
		return err
	}

	_, err = c.client.DeleteObject(context.Background(), &s3.DeleteObjectInput{
		Bucket: &c.bucket,
		Key:    &objectKey,
	})
	if err != nil {
		return fmt.Errorf("delete object: %w", err)
	}
	return nil
}

func (c *S3Client) ListKeys() ([]string, error) {
	keys := make([]string, 0)
	paginator := s3.NewListObjectsV2Paginator(c.client, &s3.ListObjectsV2Input{
		Bucket: &c.bucket,
		Prefix: aws.String(c.prefix),
	})

	for paginator.HasMorePages() {
		page, err := paginator.NextPage(context.Background())
		if err != nil {
			return nil, fmt.Errorf("list objects: %w", err)
		}
		for _, obj := range page.Contents {
			if obj.Key == nil {
				continue
			}
			trimmed := strings.TrimPrefix(*obj.Key, c.prefix)
			if trimmed != "" {
				keys = append(keys, trimmed)
			}
		}
	}

	sort.Strings(keys)
	return keys, nil
}

func (c *S3Client) prefixedKey(key string) (string, error) {
	cleaned := strings.TrimSpace(strings.ReplaceAll(key, "\\", "/"))
	if cleaned == "" {
		return "", errors.New("object key cannot be empty")
	}
	if strings.HasPrefix(cleaned, "/") || strings.HasPrefix(cleaned, "../") || strings.Contains(cleaned, "/../") {
		return "", errors.New("invalid object key")
	}
	return c.prefix + cleaned, nil
}
