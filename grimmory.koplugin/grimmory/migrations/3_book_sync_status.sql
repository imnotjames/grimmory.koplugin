CREATE TABLE IF NOT EXISTS book_sync_status (
    id        integer PRIMARY KEY autoincrement,
    book_id        INTEGER NOT NULL,
    sync_type      VARCHAR NOT NULL,
    last_synced_at INTEGER NOT NULL DEFAULT 0,
    UNIQUE (book_id, sync_type)
    FOREIGN KEY(book_id) REFERENCES book(id)
);