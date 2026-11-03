# Context injection options

## How it works

Models keep nothing between requests. The model only "remembers" what is in the prompt you send.

1. **Embed.** An embedding model turns each piece of stored text (a past message, a fact, a document chunk) into a vector. Similar meanings get nearby vectors.
2. **Store.** Vectors and their text go into a vector store, such as Postgres with pgvector. An index (for example HNSW) makes nearest-neighbor lookups fast.
3. **Search.** A new question is embedded with the same model. The store returns the closest stored texts, usually by cosine similarity.
4. **Inject.** The application pastes those texts into `messages` and calls chat completions. The model answers with that context.

Notes:

- Stored text and queries must use the same embedding model. Changing it means re-embedding everything.
- Split long text into chunks before embedding. Short summaries or facts usually retrieve better than full transcripts.
- Injected text uses up the context window. Keep it short, or raise the model's context length.

## Options for API clients

`/v1/chat/completions` is stateless, so a client app has to supply the history.

### 1. Client-side retrieval (current setup)

The stack serves `/v1/embeddings` (`embed/nomic-embed-text`). Each app runs steps 1–4 itself and keeps its own vector store.

- The stack holds no one's history. Usage is tracked per LiteLLM key.
- Each team builds its own storage and search.

### 2. Shared memory service

A small service on this stack with endpoints to save and search memories, scoped by the caller's LiteLLM key, stored in pgvector in the existing Postgres. Clients call it, then call chat completions themselves.

- One implementation shared by every app.
- The stack now stores user data, so it needs rules for retention, deletion, and access.

### 3. Injection inside LiteLLM

LiteLLM does the lookup and injection itself, so clients send only the new question. Not tested against Ollama models on v1.106.5. Two related features:

- **Vector store search:** a request names a vector store, and LiteLLM adds the matching text to the prompt.
- **Responses API:** LiteLLM stores the conversation and continues it from `previous_response_id`. That is plain history, not similarity search.

Notes:

- Least work for clients. Each API client has its own key, so results can be scoped per caller.
- Retrieval happens out of the client's sight, which makes wrong answers harder to debug.
- Same data-handling rules as option 2.
