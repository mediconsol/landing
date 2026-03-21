from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from datetime import date
import sqlite3
import os

DB_PATH = os.environ.get("DB_PATH", "/data/calendar.db")

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    conn.execute("""
        CREATE TABLE IF NOT EXISTS events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            time TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT DEFAULT '',
            color TEXT DEFAULT 'var(--teal)',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_events_date ON events(date)")
    # Seed default events if table is empty
    count = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
    if count == 0:
        seed_events = [
            ("2026-03-02", "09:00", "월간 서비스 점검", "전체 서비스 상태 확인 및 보안 패치", "var(--rose)"),
            ("2026-03-05", "14:00", "RehabFlow 업데이트 배포", "v2.4 스케줄 최적화 기능 배포", "var(--teal)"),
            ("2026-03-10", "10:00", "의료진 AI 교육", "MediEdu Pro 활용 교육 세션", "var(--purple)"),
            ("2026-03-10", "15:00", "EMR 연동 회의", "RehabFlow EMR 데이터 연동 논의", "var(--purple)"),
            ("2026-03-14", "11:00", "Tidewave 스프린트 리뷰", "2주차 스프린트 결과 공유", "var(--green)"),
            ("2026-03-18", "09:30", "보안 인증 갱신", "SSL 인증서 갱신 및 점검", "var(--rose)"),
            ("2026-03-21", "10:00", "팀 주간 미팅", "주간 업무 현황 공유", "var(--teal)"),
            ("2026-03-21", "14:00", "AI Practice 신규 기능 기획", "워크플로우 템플릿 확장 논의", "var(--green)"),
            ("2026-03-25", "13:00", "Docs Hub 콘텐츠 리뷰", "신규 서비스 가이드 문서 검토", "var(--amber)"),
            ("2026-03-28", "16:00", "월말 인프라 점검", "Docker 컨테이너 및 네트워크 정기 점검", "var(--rose)"),
            ("2026-04-01", "09:00", "4월 정기 미팅", "월간 계획 수립 및 목표 설정", "var(--teal)"),
            ("2026-04-07", "14:00", "MediEdu Pro 2 런칭 리뷰", "2세대 교육 플랫폼 성과 분석", "var(--purple)"),
            ("2026-04-15", "10:00", "분기 보안 감사", "전체 서비스 보안 감사 수행", "var(--rose)"),
        ]
        conn.executemany(
            "INSERT INTO events (date, time, title, description, color) VALUES (?, ?, ?, ?, ?)",
            seed_events,
        )
    conn.commit()
    conn.close()


init_db()


class EventCreate(BaseModel):
    date: str
    time: str
    title: str
    description: str = ""
    color: str = "var(--teal)"


class EventUpdate(BaseModel):
    date: str | None = None
    time: str | None = None
    title: str | None = None
    description: str | None = None
    color: str | None = None


def row_to_dict(row):
    return dict(row)


@app.get("/api/events")
def list_events(month: str | None = None):
    """List events. Optional filter by month (YYYY-MM)."""
    conn = get_db()
    if month:
        rows = conn.execute(
            "SELECT * FROM events WHERE date LIKE ? ORDER BY date, time",
            (month + "%",),
        ).fetchall()
    else:
        rows = conn.execute("SELECT * FROM events ORDER BY date, time").fetchall()
    conn.close()
    return [row_to_dict(r) for r in rows]


@app.get("/api/events/{event_id}")
def get_event(event_id: int):
    conn = get_db()
    row = conn.execute("SELECT * FROM events WHERE id = ?", (event_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="Event not found")
    return row_to_dict(row)


@app.post("/api/events", status_code=201)
def create_event(event: EventCreate):
    conn = get_db()
    cursor = conn.execute(
        "INSERT INTO events (date, time, title, description, color) VALUES (?, ?, ?, ?, ?)",
        (event.date, event.time, event.title, event.description, event.color),
    )
    conn.commit()
    row = conn.execute("SELECT * FROM events WHERE id = ?", (cursor.lastrowid,)).fetchone()
    conn.close()
    return row_to_dict(row)


@app.put("/api/events/{event_id}")
def update_event(event_id: int, event: EventUpdate):
    conn = get_db()
    existing = conn.execute("SELECT * FROM events WHERE id = ?", (event_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(status_code=404, detail="Event not found")

    updates = {k: v for k, v in event.model_dump().items() if v is not None}
    if not updates:
        conn.close()
        return row_to_dict(existing)

    set_clause = ", ".join(f"{k} = ?" for k in updates)
    values = list(updates.values()) + [event_id]
    conn.execute(f"UPDATE events SET {set_clause} WHERE id = ?", values)
    conn.commit()
    row = conn.execute("SELECT * FROM events WHERE id = ?", (event_id,)).fetchone()
    conn.close()
    return row_to_dict(row)


@app.delete("/api/events/{event_id}")
def delete_event(event_id: int):
    conn = get_db()
    existing = conn.execute("SELECT * FROM events WHERE id = ?", (event_id,)).fetchone()
    if not existing:
        conn.close()
        raise HTTPException(status_code=404, detail="Event not found")
    conn.execute("DELETE FROM events WHERE id = ?", (event_id,))
    conn.commit()
    conn.close()
    return {"ok": True}
