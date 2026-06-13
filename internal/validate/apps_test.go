package validate_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/admte/orc-apps/internal/validate"
)

func TestAppConfigBlobs(t *testing.T) {
	t.Helper()

	root := filepath.Join("..", "..", "apps")
	var configs []string
	err := filepath.WalkDir(root, func(path string, d os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			return nil
		}
		if d.Name() != "app.config.v1.json" {
			return nil
		}
		configs = append(configs, path)
		return nil
	})
	require.NoError(t, err)
	require.NotEmpty(t, configs, "expected at least one app config blob under apps/")

	for _, path := range configs {
		path := path
		rel, err := filepath.Rel(root, path)
		require.NoError(t, err)
		testName := strings.TrimSuffix(rel, ".json")
		t.Run(testName, func(t *testing.T) {
			t.Helper()
			body, err := os.ReadFile(path)
			require.NoError(t, err)

			cfg, err := validate.ParseAppConfig(body)
			require.NoError(t, err)
			require.NotEmpty(t, cfg.Description)
			require.NotNil(t, cfg.Start, "%s must define start", testName)
			require.NotEmpty(t, cfg.Start.Command, "%s start.command is required", testName)
		})
	}
}
