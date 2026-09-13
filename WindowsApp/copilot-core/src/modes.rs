//! Session modes and their system prompts / quick actions.
//!
//! Ported from `SessionMode.swift`. `{NAME}` / `{ROLE}` / `{COMPANY}` markers
//! are substituted by [`crate::prompt::resolve_system_prompt`] at send time.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SessionMode {
    #[default]
    General,
    Interview,
    Meeting,
    Call,
}

/// A one-tap prompt prefix for the current mode.
#[derive(Debug, Clone, Copy)]
pub struct QuickAction {
    pub label: &'static str,
    pub prompt_prefix: &'static str,
}

impl SessionMode {
    pub const ALL: [SessionMode; 4] = [
        SessionMode::General,
        SessionMode::Interview,
        SessionMode::Meeting,
        SessionMode::Call,
    ];

    pub fn display_name(self) -> &'static str {
        match self {
            SessionMode::General => "General",
            SessionMode::Interview => "Interview",
            SessionMode::Meeting => "Meeting",
            SessionMode::Call => "Call",
        }
    }

    /// The raw system prompt, still containing `{NAME}`/`{ROLE}`/`{COMPANY}`
    /// markers. Use [`crate::prompt::resolve_system_prompt`] to fill them.
    pub fn system_prompt(self) -> &'static str {
        match self {
            SessionMode::General => {
                "You are a concise personal assistant running as a floating overlay on the user's PC. \
The user may send you live transcription from a meeting or call, manual notes, or a screenshot. \
Respond helpfully and concisely. Prefer bullet points for structured answers. \
Do not repeat the user's text back to them unless quoting for clarity."
            }
            SessionMode::Interview => {
                "You are a real-time interview copilot. The user is IN a live job interview right now; \
the interviewer's words arrive as transcript messages and the user reads your reply \
while speaking. Every second counts, so format for instant scanning:

- FIRST LINE: the direct opening sentence the user can say verbatim, immediately. \
No preamble, no \"Great question\", no headings, never restate the question.
- Then at most 3 short bullets expanding the answer — a concrete example, a metric, \
a closing point. Bold the 2-3 keywords that matter so they pop while skimming.
- Technical questions: lead with the key idea/answer, then the minimal steps or a \
short snippet. Behavioral questions: structure as situation -> action -> result \
without labelling the framework.
- Ground every answer in the attached resume/JD/context when present — use the \
user's real projects, employers, and stack, never invented ones.
- If the transcript is a statement rather than a question, reply with one line the \
user could naturally say next.

User context: {NAME} is a {ROLE} at {COMPANY}. Pitch answers at their level."
            }
            SessionMode::Meeting => {
                "You are a real-time meeting assistant running as a floating overlay. The user is in a work meeting. Your job is to:
1. Summarise what has been said clearly in bullet form when asked.
2. Identify action items, owners, and deadlines from transcription.
3. When asked what to say next, suggest clarifying or probing questions relevant to the discussion.
4. Flag any decisions made or commitments given.
5. Keep responses short — the user is in a live meeting. Max 5 bullets.

User context: {NAME} is a {ROLE} at {COMPANY}."
            }
            SessionMode::Call => {
                "You are a real-time call assistant running as a floating overlay. The user is on a phone or video call. Your job is to:
1. Summarise the key points of the conversation so far.
2. Suggest concise, professional responses to what the other party has said.
3. When asked to rephrase, make the user's intended response clearer and more natural.
4. Flag any commitments or follow-up items mentioned.
5. Keep all responses brief — max 3 bullet points or 2 sentences.

User context: {NAME} is a {ROLE} at {COMPANY}."
            }
        }
    }

    pub fn quick_actions(self) -> &'static [QuickAction] {
        use QuickAction as Q;
        match self {
            SessionMode::General => &[
                Q { label: "Summarise",    prompt_prefix: "Give a concise bullet-point summary of the following:\n\n" },
                Q { label: "Key points",   prompt_prefix: "Extract the 3-5 most important points from the following:\n\n" },
                Q { label: "Rephrase",     prompt_prefix: "Rephrase the following more clearly and professionally:\n\n" },
                Q { label: "Explain",      prompt_prefix: "Explain the following simply:\n\n" },
                Q { label: "What to ask?", prompt_prefix: "Based on the following, what are the best follow-up questions to ask?\n\n" },
            ],
            SessionMode::Interview => &[
                Q { label: "Suggest answer", prompt_prefix: "The interviewer just asked the following question. Suggest a strong, structured answer I can use:\n\n" },
                Q { label: "Key points",     prompt_prefix: "Extract the 3-5 most important points from what the interviewer said:\n\n" },
                Q { label: "Rephrase",       prompt_prefix: "Rephrase the following to sound more confident and professional:\n\n" },
                Q { label: "What to ask?",   prompt_prefix: "Based on this interview so far, what are the best questions I can ask the interviewer?\n\n" },
                Q { label: "Summarise",      prompt_prefix: "Give a concise summary of this interview conversation so far:\n\n" },
            ],
            SessionMode::Meeting => &[
                Q { label: "Action items",  prompt_prefix: "List all action items, owners, and deadlines from the following meeting transcript:\n\n" },
                Q { label: "Summarise",     prompt_prefix: "Give a concise bullet-point summary of everything discussed so far:\n\n" },
                Q { label: "What to ask?",  prompt_prefix: "Based on this meeting so far, what are the best questions or points to raise next?\n\n" },
                Q { label: "Key decisions", prompt_prefix: "What key decisions or commitments were made in the following discussion?\n\n" },
                Q { label: "Rephrase",      prompt_prefix: "Rephrase the following more clearly and professionally for a meeting context:\n\n" },
            ],
            SessionMode::Call => &[
                Q { label: "Suggest response", prompt_prefix: "The other person just said the following. Suggest a concise, professional response:\n\n" },
                Q { label: "Summarise",        prompt_prefix: "Give a concise summary of this call so far:\n\n" },
                Q { label: "Rephrase",         prompt_prefix: "Rephrase the following more clearly and naturally for a phone call:\n\n" },
                Q { label: "Follow-ups",       prompt_prefix: "List any follow-up items or commitments mentioned in the following:\n\n" },
                Q { label: "Key points",       prompt_prefix: "Extract the 3-5 most important points from the following call transcript:\n\n" },
            ],
        }
    }
}
