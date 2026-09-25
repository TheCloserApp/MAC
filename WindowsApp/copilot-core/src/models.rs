//! Model catalogue + provider routing.
//!
//! Mirrors `OverlayViewModel.availableModels` and the `AIManager` `is…Model`
//! prefix rules: one picker spans Anthropic and several OpenAI-compatible
//! providers, and a model id alone determines where the request goes.

use crate::ai::ProviderKeys;

/// One entry in the model picker.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ModelInfo {
    /// Routing id (e.g. `claude-opus-4-8`, `openrouter/openai/gpt-4.1`).
    pub id: &'static str,
    /// Human-facing label.
    pub name: &'static str,
    /// Provider display name (also the heading in the picker).
    pub provider: &'static str,
}

/// The full catalogue, in display order. Kept byte-for-byte in sync with the
/// macOS app's `availableModels`.
pub fn available_models() -> &'static [ModelInfo] {
    use ModelInfo as M;
    &[
        // Anthropic
        M { id: "claude-fable-5",            name: "Fable 5",      provider: "Anthropic" },
        M { id: "claude-opus-4-8",           name: "Opus 4.8",     provider: "Anthropic" },
        M { id: "claude-opus-4-7",           name: "Opus 4.7",     provider: "Anthropic" },
        M { id: "claude-opus-4-6",           name: "Opus 4.6",     provider: "Anthropic" },
        M { id: "claude-sonnet-4-6",         name: "Sonnet 4.6",   provider: "Anthropic" },
        M { id: "claude-haiku-4-5-20251001", name: "Haiku 4.5",    provider: "Anthropic" },
        // OpenAI
        M { id: "gpt-5.5",                   name: "GPT-5.5",      provider: "OpenAI" },
        M { id: "gpt-5.5-mini",              name: "GPT-5.5 mini", provider: "OpenAI" },
        M { id: "gpt-5.5-pro",               name: "GPT-5.5 pro",  provider: "OpenAI" },
        M { id: "gpt-5.4",                   name: "GPT-5.4",      provider: "OpenAI" },
        M { id: "gpt-4.1",                   name: "GPT-4.1",      provider: "OpenAI" },
        M { id: "gpt-4.1-mini",              name: "GPT-4.1 mini", provider: "OpenAI" },
        // Kimi (Moonshot)
        M { id: "kimi-k2.7-code",            name: "Kimi 2.7 Code", provider: "Kimi" },
        M { id: "kimi-k2.6",                 name: "Kimi 2.6",      provider: "Kimi" },
        M { id: "kimi-k2.5",                 name: "Kimi 2.5",      provider: "Kimi" },
        // Grok (xAI)
        M { id: "grok-4.3",                  name: "Grok 4.3",      provider: "Grok" },
        // DeepSeek
        M { id: "deepseek-v4-pro",           name: "DeepSeek V4 Pro",   provider: "DeepSeek" },
        M { id: "deepseek-v4-flash",         name: "DeepSeek V4 Flash", provider: "DeepSeek" },
        // NVIDIA NIM
        M { id: "deepseek-ai/deepseek-v4-pro",   name: "DeepSeek V4 Pro (NVIDIA)",   provider: "NVIDIA" },
        M { id: "deepseek-ai/deepseek-v4-flash", name: "DeepSeek V4 Flash (NVIDIA)", provider: "NVIDIA" },
        // OpenRouter
        M { id: "openrouter/deepseek/deepseek-chat",      name: "DeepSeek (OpenRouter)",         provider: "OpenRouter" },
        M { id: "openrouter/anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5 (OpenRouter)", provider: "OpenRouter" },
        M { id: "openrouter/openai/gpt-4.1",              name: "GPT-4.1 (OpenRouter)",          provider: "OpenRouter" },
    ]
}

/// Which request/response shape a route uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Api {
    /// `https://api.anthropic.com/v1/messages` shape.
    Anthropic,
    /// OpenAI `chat/completions` shape (also Moonshot/Grok/DeepSeek/NVIDIA/OpenRouter).
    OpenAiCompatible,
}

/// A fully resolved destination for a model id: where to POST, with which key,
/// using which body shape.
#[derive(Debug, Clone)]
pub struct Route {
    pub api: Api,
    pub endpoint: &'static str,
    /// The provider key to authenticate with (cloned out of [`ProviderKeys`]).
    pub api_key: String,
    /// The real model id sent on the wire (the `openrouter/` prefix is stripped).
    pub model: String,
    /// `max_tokens` vs `max_completion_tokens` — OpenAI's reasoning models
    /// reject the old field, but the compatible providers still want it.
    pub token_field: &'static str,
    /// Provider display name, for "add a key for …" messaging.
    pub provider_name: &'static str,
}

pub const OPENAI_ENDPOINT: &str = "https://api.openai.com/v1/chat/completions";
pub const MOONSHOT_ENDPOINT: &str = "https://api.moonshot.ai/v1/chat/completions";
pub const GROK_ENDPOINT: &str = "https://api.x.ai/v1/chat/completions";
pub const DEEPSEEK_ENDPOINT: &str = "https://api.deepseek.com/chat/completions";
pub const NVIDIA_ENDPOINT: &str = "https://integrate.api.nvidia.com/v1/chat/completions";
pub const OPENROUTER_ENDPOINT: &str = "https://openrouter.ai/api/v1/chat/completions";
pub const ANTHROPIC_ENDPOINT: &str = "https://api.anthropic.com/v1/messages";

const OPENROUTER_PREFIX: &str = "openrouter/";
const OPENAI_PREFIXES: [&str; 4] = ["gpt-", "o1", "o3", "o4"];
const MOONSHOT_PREFIXES: [&str; 2] = ["kimi", "moonshot-"];

pub fn is_openrouter_model(model: &str) -> bool {
    model.starts_with(OPENROUTER_PREFIX)
}
/// NVIDIA NIM ids are `vendor/model`; the slash is unique to them across the
/// catalogue (checked *after* OpenRouter, whose stripped id also has a slash).
pub fn is_nvidia_model(model: &str) -> bool {
    model.contains('/')
}
pub fn is_moonshot_model(model: &str) -> bool {
    MOONSHOT_PREFIXES.iter().any(|p| model.starts_with(p))
}
pub fn is_grok_model(model: &str) -> bool {
    model.starts_with("grok")
}
pub fn is_deepseek_model(model: &str) -> bool {
    model.starts_with("deepseek")
}
pub fn is_openai_model(model: &str) -> bool {
    OPENAI_PREFIXES.iter().any(|p| model.starts_with(p))
}

/// Resolve a model id to a concrete destination, exactly following the
/// precedence in `AIManager.sendMessage`: OpenRouter → NVIDIA → Moonshot →
/// Grok → DeepSeek → OpenAI → Anthropic (the default).
pub fn route(model: &str, keys: &ProviderKeys) -> Route {
    if is_openrouter_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: OPENROUTER_ENDPOINT,
            api_key: keys.openrouter.clone(),
            model: model[OPENROUTER_PREFIX.len()..].to_string(),
            token_field: "max_tokens",
            provider_name: "OpenRouter",
        };
    }
    if is_nvidia_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: NVIDIA_ENDPOINT,
            api_key: keys.nvidia.clone(),
            model: model.to_string(),
            token_field: "max_tokens",
            provider_name: "NVIDIA",
        };
    }
    if is_moonshot_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: MOONSHOT_ENDPOINT,
            api_key: keys.moonshot.clone(),
            model: model.to_string(),
            token_field: "max_tokens",
            provider_name: "Kimi",
        };
    }
    if is_grok_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: GROK_ENDPOINT,
            api_key: keys.grok.clone(),
            model: model.to_string(),
            token_field: "max_tokens",
            provider_name: "Grok",
        };
    }
    if is_deepseek_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: DEEPSEEK_ENDPOINT,
            api_key: keys.deepseek.clone(),
            model: model.to_string(),
            token_field: "max_tokens",
            provider_name: "DeepSeek",
        };
    }
    if is_openai_model(model) {
        return Route {
            api: Api::OpenAiCompatible,
            endpoint: OPENAI_ENDPOINT,
            api_key: keys.openai.clone(),
            model: model.to_string(),
            token_field: "max_completion_tokens",
            provider_name: "OpenAI",
        };
    }
    Route {
        api: Api::Anthropic,
        endpoint: ANTHROPIC_ENDPOINT,
        api_key: keys.anthropic.clone(),
        model: model.to_string(),
        token_field: "max_tokens",
        provider_name: "Anthropic",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys() -> ProviderKeys {
        ProviderKeys {
            anthropic: "ant".into(),
            openai: "oai".into(),
            moonshot: "moon".into(),
            grok: "grok".into(),
            deepseek: "deep".into(),
            nvidia: "nv".into(),
            openrouter: "or".into(),
        }
    }

    #[test]
    fn catalogue_ids_route_to_their_advertised_provider() {
        // Every catalogue entry must resolve to a route whose key matches the
        // provider column — this is the contract the picker relies on.
        let k = keys();
        for m in available_models() {
            let r = route(m.id, &k);
            assert_eq!(
                r.provider_name, m.provider,
                "model {} advertised provider {} but routed to {}",
                m.id, m.provider, r.provider_name
            );
        }
    }

    #[test]
    fn openrouter_wins_over_nvidia_and_strips_prefix() {
        let r = route("openrouter/openai/gpt-4.1", &keys());
        assert_eq!(r.endpoint, OPENROUTER_ENDPOINT);
        assert_eq!(r.model, "openai/gpt-4.1"); // prefix stripped
        assert_eq!(r.api_key, "or");
    }

    #[test]
    fn nvidia_wins_over_deepseek() {
        // `deepseek-ai/…` carries a slash → NVIDIA, not the plain deepseek key.
        let r = route("deepseek-ai/deepseek-v4-pro", &keys());
        assert_eq!(r.endpoint, NVIDIA_ENDPOINT);
        assert_eq!(r.api_key, "nv");
        assert_eq!(r.token_field, "max_tokens");
    }

    #[test]
    fn openai_reasoning_uses_completion_tokens_field() {
        let r = route("gpt-5.5", &keys());
        assert_eq!(r.api, Api::OpenAiCompatible);
        assert_eq!(r.token_field, "max_completion_tokens");
        assert_eq!(r.api_key, "oai");
    }

    #[test]
    fn unknown_id_defaults_to_anthropic() {
        let r = route("claude-opus-4-8", &keys());
        assert_eq!(r.api, Api::Anthropic);
        assert_eq!(r.endpoint, ANTHROPIC_ENDPOINT);
        assert_eq!(r.api_key, "ant");
    }
}
