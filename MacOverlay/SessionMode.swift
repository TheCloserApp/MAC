import Foundation

enum SessionMode: String, CaseIterable, Codable {
    case general, interview, meeting, call

    var displayName: String {
        switch self {
        case .general:   return "General"
        case .interview: return "Interview"
        case .meeting:   return "Meeting"
        case .call:      return "Call"
        }
    } 

    var icon: String {
        switch self {
        case .general:   return "brain"
        case .interview: return "person.fill.checkmark"
        case .meeting:   return "person.3.fill"
        
        case .call:      return "phone.fill"
        }
    }

    var systemPrompt: String {
        switch self {
        case .general:
            return """
            You are a concise personal assistant running as a floating overlay on the user's Mac. \
            The user may send you live transcription from a meeting or call, manual notes, or a screenshot. \
            Respond helpfully and concisely. Prefer bullet points for structured answers. \
            Do not repeat the user's text back to them unless quoting for clarity.
            """
        case .interview:
            return """
            You are a real-time interview copilot. The user is IN a live job interview right now; \
            the interviewer's words arrive as transcript messages and the user reads your reply \
            while speaking. Every second counts, so format for instant scanning:

            - FIRST LINE: the direct opening sentence the user can say verbatim, immediately. \
            No preamble, no "Great question", no headings, never restate the question.
            - Then at most 3 short bullets expanding the answer — a concrete example, a metric, \
            a closing point. Bold the 2–3 keywords that matter so they pop while skimming.
            - Technical questions: lead with the key idea/answer, then the minimal steps or a \
            short snippet. Behavioral questions: structure as situation → action → result \
            without labelling the framework.
            - Ground every answer in the attached resume/JD/context when present — use the \
            user's real projects, employers, and stack, never invented ones.
            - If the transcript is a statement rather than a question, reply with one line the \
            user could naturally say next.

            User context: {NAME} is a {ROLE} at {COMPANY}. Pitch answers at their level.
            """
        case .meeting:
            return """
            You are a real-time meeting assistant running as a floating overlay. The user is in a work meeting. Your job is to:
            1. Summarise what has been said clearly in bullet form when asked.
            2. Identify action items, owners, and deadlines from transcription.
            3. When asked what to say next, suggest clarifying or probing questions relevant to the discussion.
            4. Flag any decisions made or commitments given.
            5. Keep responses short — the user is in a live meeting. Max 5 bullets.

            User context: {NAME} is a {ROLE} at {COMPANY}.
            """
        case .call:
            return """
            You are a real-time call assistant running as a floating overlay. The user is on a phone or video call. Your job is to:
            1. Summarise the key points of the conversation so far.
            2. Suggest concise, professional responses to what the other party has said.
            3. When asked to rephrase, make the user's intended response clearer and more natural.
            4. Flag any commitments or follow-up items mentioned.
            5. Keep all responses brief — max 3 bullet points or 2 sentences.

            User context: {NAME} is a {ROLE} at {COMPANY}.
            """
        }
    }

    var quickActions: [QuickAction] {
        switch self {
        case .general:
            return [
                QuickAction(label: "Summarise",     promptPrefix: "Give a concise bullet-point summary of the following:\n\n"),
                QuickAction(label: "Key points",    promptPrefix: "Extract the 3–5 most important points from the following:\n\n"),
                QuickAction(label: "Rephrase",      promptPrefix: "Rephrase the following more clearly and professionally:\n\n"),
                QuickAction(label: "Explain",       promptPrefix: "Explain the following simply:\n\n"),
                QuickAction(label: "What to ask?",  promptPrefix: "Based on the following, what are the best follow-up questions to ask?\n\n"),
            ]
        case .interview:
            return [
                QuickAction(label: "Suggest answer",  promptPrefix: "The interviewer just asked the following question. Suggest a strong, structured answer I can use:\n\n"),
                QuickAction(label: "Key points",      promptPrefix: "Extract the 3–5 most important points from what the interviewer said:\n\n"),
                QuickAction(label: "Rephrase",        promptPrefix: "Rephrase the following to sound more confident and professional:\n\n"),
                QuickAction(label: "What to ask?",    promptPrefix: "Based on this interview so far, what are the best questions I can ask the interviewer?\n\n"),
                QuickAction(label: "Summarise",       promptPrefix: "Give a concise summary of this interview conversation so far:\n\n"),
            ]
        case .meeting:
            return [
                QuickAction(label: "Action items",   promptPrefix: "List all action items, owners, and deadlines from the following meeting transcript:\n\n"),
                QuickAction(label: "Summarise",      promptPrefix: "Give a concise bullet-point summary of everything discussed so far:\n\n"),
                QuickAction(label: "What to ask?",   promptPrefix: "Based on this meeting so far, what are the best questions or points to raise next?\n\n"),
                QuickAction(label: "Key decisions",  promptPrefix: "What key decisions or commitments were made in the following discussion?\n\n"),
                QuickAction(label: "Rephrase",       promptPrefix: "Rephrase the following more clearly and professionally for a meeting context:\n\n"),
            ]
        case .call:
            return [
                QuickAction(label: "Suggest response", promptPrefix: "The other person just said the following. Suggest a concise, professional response:\n\n"),
                QuickAction(label: "Summarise",        promptPrefix: "Give a concise summary of this call so far:\n\n"),
                QuickAction(label: "Rephrase",         promptPrefix: "Rephrase the following more clearly and naturally for a phone call:\n\n"),
                QuickAction(label: "Follow-ups",       promptPrefix: "List any follow-up items or commitments mentioned in the following:\n\n"),
                QuickAction(label: "Key points",       promptPrefix: "Extract the 3–5 most important points from the following call transcript:\n\n"),
            ]
        }
    }
}

struct QuickAction: Identifiable {
    let id   = UUID()
    let label: String
    let promptPrefix: String
}
