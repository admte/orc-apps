package validate

import (
	"encoding/json"
	"fmt"
	"strings"
)

// AppConfig is a minimal subset of the OCI app config blob used for repo validation.
type AppConfig struct {
	Description string      `json:"description"`
	Params      *JSONSchema `json:"params,omitempty"`
	Start       *Lifecycle  `json:"start,omitempty"`
	Install     *Lifecycle  `json:"install,omitempty"`
}

type JSONSchema struct {
	Type       string                     `json:"type"`
	Required   []string                   `json:"required,omitempty"`
	Properties map[string]json.RawMessage `json:"properties,omitempty"`
}

type Lifecycle struct {
	Command string `json:"command,omitempty"`
	Service string `json:"service,omitempty"`
}

// ParseAppConfig decodes an OCI app config blob (application/vnd.orc8r.app.config.v1+json).
func ParseAppConfig(body []byte) (*AppConfig, error) {
	var cfg AppConfig
	if err := json.Unmarshal(body, &cfg); err != nil {
		return nil, fmt.Errorf("decode app config: %w", err)
	}
	if cfg.Params != nil && strings.TrimSpace(cfg.Params.Type) == "" {
		cfg.Params.Type = "object"
	}
	return &cfg, nil
}
