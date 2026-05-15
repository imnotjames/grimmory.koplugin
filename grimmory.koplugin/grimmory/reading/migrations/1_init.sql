CREATE TABLE IF NOT EXISTS book
(
    id          integer PRIMARY KEY autoincrement,
    book_path   text NOT NULL,
    partial_md5 text NOT NULL,
    full_md5    text NOT NULL,
    UNIQUE (book_path, full_md5),
    UNIQUE (book_path, partial_md5)
);

CREATE TABLE IF NOT EXISTS book_session
(
    id           integer PRIMARY KEY autoincrement,
    book_id      integer NOT NULL,
    FOREIGN KEY(book_id) REFERENCES book(id)
);

CREATE TABLE IF NOT EXISTS book_event
(
    id           integer PRIMARY KEY autoincrement,
    session_id   integer NOT NULL,
    event_type   text NOT NULL,
    created_at   integer NOT NULL DEFAULT 0,
    current_page integer NOT NULL DEFAULT 0,
    page_count   integer NOT NULL DEFAULT 0,
    xpointer     text,
    FOREIGN KEY(session_id) REFERENCES book_session(id)
);