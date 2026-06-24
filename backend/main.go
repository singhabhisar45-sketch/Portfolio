package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	_ "github.com/lib/pq"
	"google.golang.org/api/option"
)

var db *sql.DB
var fcmClient *messaging.Client

type User struct {
	Username    string    `json:"username"`
	Password    string    `json:"password"`
	DisplayName string    `json:"display_name"`
	IsOnline    bool      `json:"is_online"`
	DeviceID    string    `json:"device_id"`
	FCMToken    string    `json:"fcm_token"`
	PhotoURL    string    `json:"photo_url"`
	LastSeen    time.Time `json:"last_seen"`
}

type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
	DeviceID string `json:"device_id"`
}

type LoginResponse struct {
	Success     bool   `json:"success"`
	Message     string `json:"message"`
	DisplayName string `json:"display_name"`
}

type SaveFCMTokenRequest struct {
	Username string `json:"username"`
	FCMToken string `json:"fcm_token"`
}

type HelpRequest struct {
	UserName string `json:"user_name"`
	Message  string `json:"message"`
}

type WorkItem struct {
	ID         int    `json:"id"`
	Title      string `json:"title"`
	AssigneeID string `json:"assignee_id"`
	Assignee   string `json:"assignee"`
	AssignedBy string `json:"assigned_by"`
	IsDone     bool   `json:"is_done"`
}

type Room struct {
	ID      int      `json:"id"`
	Name    string   `json:"name"`
	Creator string   `json:"creator"`
	Members []string `json:"members"`
}

type ChatMessage struct {
	ID          int    `json:"id"`
	RoomID      int    `json:"room_id"`
	SenderID    string `json:"sender_id"`
	SenderName  string `json:"sender_name"`
	ReceiverID  string `json:"receiver_id"`
	Text        string `json:"text"`
	MediaURL    string `json:"media_url"`
	MediaType   string `json:"media_type"`
	ImageBase64 string `json:"image_base64"`
	CreatedAt   string `json:"created_at"`
	IsRead      bool   `json:"is_read"`
}

type Broadcast struct {
	ID          int    `json:"id"`
	SenderID    string `json:"sender_id"`
	Text        string `json:"text"`
	MediaURL    string `json:"media_url"`
	MediaType   string `json:"media_type"`
	ImageBase64 string `json:"image_base64"`
	CreatedAt   string `json:"created_at"`
}

var (
	latestVersion = "1.0.0"
	apkFileName   = "uploads/app-latest.apk"
	updateTitle   = "New Features Available!"
	updateContent = `- Improvements and bug fixes`
)

var seedUsers = map[string]User{
	"admin": {Password: "password", DisplayName: "Admin"},
}

func initFirebase() {
	opt := option.WithCredentialsFile("serviceAccountKey.json")
	app, err := firebase.NewApp(context.Background(), nil, opt)
	if err != nil {
		log.Printf("[FCM] Error initializing firebase app: %v\n", err)
		return
	}
	fcmClient, err = app.Messaging(context.Background())
	if err != nil {
		log.Printf("[FCM] Error getting Messaging client: %v\n", err)
		return
	}
	log.Println("[FCM] Firebase initialized successfully")
}

func sendNotification(token, title, body string) {
	if fcmClient == nil {
		log.Printf("[FCM] Skipping notification — Firebase not initialized. title=%q body=%q", title, body)
		return
	}
	if token == "" {
		log.Printf("[FCM] Skipping notification — empty token. title=%q body=%q", title, body)
		return
	}
	log.Printf("[FCM] Sending notification to token=%s... title=%q body=%q", token[:min(10, len(token))], title, body)
	message := &messaging.Message{
		Notification: &messaging.Notification{
			Title: title,
			Body:  body,
		},
		Token: token,
	}
	msgID, err := fcmClient.Send(context.Background(), message)
	if err != nil {
		log.Printf("[FCM] Error sending notification: %v", err)
		return
	}
	log.Printf("[FCM] Notification sent successfully. messageID=%s", msgID)
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func initDB() {
	var err error
	connStr := "postgresql://username:password@localhost:5432/database?sslmode=disable"
	db, err = sql.Open("postgres", connStr)
	if err != nil {
		log.Fatal(err)
	}

	queries := []string{
		`CREATE TABLE IF NOT EXISTS users (
			username TEXT PRIMARY KEY,
			password TEXT,
			display_name TEXT,
			is_online BOOLEAN DEFAULT false,
			device_id TEXT DEFAULT '',
			fcm_token TEXT DEFAULT '',
			photo_url TEXT DEFAULT '',
			last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS help_requests (
			id SERIAL PRIMARY KEY,
			user_name TEXT,
			message TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS tasks (
			id SERIAL PRIMARY KEY,
			title TEXT,
			assignee_id TEXT,
			assignee TEXT,
			assigned_by TEXT,
			is_done BOOLEAN DEFAULT false
		)`,
		`CREATE TABLE IF NOT EXISTS rooms (
			id SERIAL PRIMARY KEY,
			name TEXT,
			creator TEXT
		)`,
		`CREATE TABLE IF NOT EXISTS room_members (
			room_id INTEGER REFERENCES rooms(id) ON DELETE CASCADE,
			username TEXT,
			PRIMARY KEY (room_id, username)
		)`,
		`CREATE TABLE IF NOT EXISTS private_messages (
			id SERIAL PRIMARY KEY,
			sender_id TEXT,
			sender_name TEXT,
			receiver_id TEXT,
			text TEXT,
			media_url TEXT,
			media_type TEXT,
			image_base64 TEXT,
			is_read BOOLEAN DEFAULT false,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS room_messages (
			id SERIAL PRIMARY KEY,
			room_id INTEGER REFERENCES rooms(id) ON DELETE CASCADE,
			sender_id TEXT,
			sender_name TEXT,
			text TEXT,
			media_url TEXT,
			media_type TEXT,
			image_base64 TEXT,
			is_read BOOLEAN DEFAULT false,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
		)`,
		`CREATE TABLE IF NOT EXISTS broadcasts (
			id SERIAL PRIMARY KEY,
			sender_id TEXT,
			text TEXT,
			media_url TEXT,
			media_type TEXT,
			created_at TEXT
		)`,
	}

	for _, q := range queries {
		if _, err := db.Exec(q); err != nil {
			log.Printf("Error creating table: %v", err)
		}
	}

	db.Exec("ALTER TABLE private_messages ADD COLUMN IF NOT EXISTS image_base64 TEXT")
	db.Exec("ALTER TABLE private_messages ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT false")
	db.Exec("ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS image_base64 TEXT")
	db.Exec("ALTER TABLE room_messages ADD COLUMN IF NOT EXISTS is_read BOOLEAN DEFAULT false")
	db.Exec("ALTER TABLE broadcasts ADD COLUMN IF NOT EXISTS image_base64 TEXT")
	db.Exec("ALTER TABLE users ADD COLUMN IF NOT EXISTS photo_url TEXT DEFAULT ''")
	db.Exec("ALTER TABLE users ADD COLUMN IF NOT EXISTS fcm_token TEXT DEFAULT ''")

	for username, u := range seedUsers {
		_, err := db.Exec("INSERT INTO users (username, password, display_name) VALUES ($1, $2, $3) ON CONFLICT (username) DO UPDATE SET password = $2, display_name = $3",
			username, u.Password, u.DisplayName)
		if err != nil {
			log.Printf("Error seeding user %s: %v", username, err)
		}
	}
}

func enableCORS(w *http.ResponseWriter) {
	(*w).Header().Set("Access-Control-Allow-Origin", "*")
	(*w).Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS, DELETE, PATCH")
	(*w).Header().Set("Access-Control-Allow-Headers", "Content-Type")
}

func loginHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	var req LoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	username := strings.ToLower(strings.TrimSpace(req.Username))
	var u User
	err := db.QueryRow("SELECT password, display_name, device_id FROM users WHERE username = $1", username).Scan(&u.Password, &u.DisplayName, &u.DeviceID)
	if err != nil {
		json.NewEncoder(w).Encode(LoginResponse{Success: false, Message: "Invalid credentials"})
		return
	}

	if u.Password != req.Password {
		json.NewEncoder(w).Encode(LoginResponse{Success: false, Message: "Invalid credentials"})
		return
	}

	if u.DeviceID == "" {
		db.Exec("UPDATE users SET device_id = $1 WHERE username = $2", req.DeviceID, username)
	} else if u.DeviceID != req.DeviceID {
		json.NewEncoder(w).Encode(LoginResponse{Success: false, Message: "Locked to another device. Contact support."})
		return
	}

	db.Exec("UPDATE users SET is_online = true, last_seen = $1 WHERE username = $2", time.Now(), username)
	json.NewEncoder(w).Encode(LoginResponse{
		Success:     true,
		Message:     "Login successful",
		DisplayName: u.DisplayName,
	})
}

func saveFCMTokenHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req SaveFCMTokenRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	username := strings.ToLower(strings.TrimSpace(req.Username))
	if username == "" || req.FCMToken == "" {
		http.Error(w, "username and fcm_token are required", http.StatusBadRequest)
		return
	}

	_, err := db.Exec("UPDATE users SET fcm_token = $1 WHERE username = $2", req.FCMToken, username)
	if err != nil {
		log.Printf("[FCM] Error saving FCM token for user %s: %v", username, err)
		http.Error(w, "Failed to save token", http.StatusInternalServerError)
		return
	}

	log.Printf("[FCM] Saved FCM token for user=%s token=%s...", username, req.FCMToken[:min(10, len(req.FCMToken))])
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func statusHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	currentUser := r.URL.Query().Get("user_id")

	rows, err := db.Query(
		"SELECT username, display_name, is_online, photo_url FROM users",
	)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	var list []map[string]interface{}

	for rows.Next() {
		var id, dn, photo string
		var online bool

		rows.Scan(&id, &dn, &online, &photo)

		var lastMsg string
		var lastTime string
		var msgTime time.Time

		err := db.QueryRow(`
			SELECT text, created_at
			FROM private_messages
			WHERE (sender_id=$1 AND receiver_id=$2)
			   OR (sender_id=$2 AND receiver_id=$1)
			ORDER BY id DESC
			LIMIT 1
		`, currentUser, id).Scan(&lastMsg, &msgTime)

		if err == nil {
			lastTime = msgTime.Format("02 Jan 15:04")
		}

		list = append(list, map[string]interface{}{
			"id":           id,
			"display_name": dn,
			"is_online":    online,
			"photo_url":    photo,
			"last_msg":     lastMsg,
			"last_msg_at":  lastTime,
		})
	}

	if list == nil {
		list = []map[string]interface{}{}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(list)
}

func resetDevicesHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	var req struct {
		Username    string `json:"username"`
		RequestedBy string `json:"requested_by"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	if req.RequestedBy != "admin" {
		http.Error(w, "Unauthorized", http.StatusUnauthorized)
		return
	}

	if req.Username == "all" {
		db.Exec("UPDATE users SET device_id = ''")
	} else {
		db.Exec("UPDATE users SET device_id = '' WHERE username = $1", req.Username)
	}
	w.WriteHeader(http.StatusOK)
}

func logoutHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	var req struct {
		Username string `json:"username"`
	}
	json.NewDecoder(r.Body).Decode(&req)

	db.Exec("UPDATE users SET is_online = false WHERE username = $1", req.Username)
	json.NewEncoder(w).Encode(map[string]bool{"success": true})
}

func helpHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	if r.Method == http.MethodPost {
		var hr HelpRequest
		json.NewDecoder(r.Body).Decode(&hr)
		db.Exec("INSERT INTO help_requests (user_name, message) VALUES ($1, $2)", hr.UserName, hr.Message)
		w.WriteHeader(http.StatusCreated)
	} else if r.Method == http.MethodGet {
		rows, err := db.Query("SELECT user_name, message FROM help_requests")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		var list []HelpRequest
		for rows.Next() {
			var hr HelpRequest
			rows.Scan(&hr.UserName, &hr.Message)
			list = append(list, hr)
		}
		if list == nil {
			list = []HelpRequest{}
		}
		json.NewEncoder(w).Encode(list)
	} else if r.Method == http.MethodDelete {
		uid := r.URL.Query().Get("user_name")
		db.Exec("DELETE FROM help_requests WHERE user_name = $1", uid)
		w.WriteHeader(http.StatusOK)
	}
}

func workHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	if r.Method == http.MethodGet {
		rows, err := db.Query("SELECT id, title, assignee_id, assignee, assigned_by, is_done FROM tasks")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		list := []WorkItem{}
		for rows.Next() {
			var i WorkItem
			rows.Scan(&i.ID, &i.Title, &i.AssigneeID, &i.Assignee, &i.AssignedBy, &i.IsDone)
			list = append(list, i)
		}
		if list == nil {
			list = []WorkItem{}
		}
		json.NewEncoder(w).Encode(list)
	} else if r.Method == http.MethodPost {
		var i WorkItem
		json.NewDecoder(r.Body).Decode(&i)
		if i.AssignedBy != "admin" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		db.QueryRow("SELECT display_name FROM users WHERE username = $1", i.AssigneeID).Scan(&i.Assignee)
		db.Exec("INSERT INTO tasks (title, assignee_id, assignee, assigned_by, is_done) VALUES ($1, $2, $3, $4, $5)", i.Title, i.AssigneeID, i.Assignee, i.AssignedBy, false)

		var token string
		err := db.QueryRow("SELECT fcm_token FROM users WHERE username = $1", i.AssigneeID).Scan(&token)
		if err != nil {
			log.Printf("[FCM] Could not fetch fcm_token for assignee=%s: %v", i.AssigneeID, err)
		} else {
			sendNotification(token, "New Task Assigned", i.Title)
		}

		w.WriteHeader(http.StatusCreated)
	} else if r.Method == http.MethodPatch {
		var up struct {
			ID     int    `json:"id"`
			IsDone bool   `json:"is_done"`
			User   string `json:"user"`
		}
		json.NewDecoder(r.Body).Decode(&up)
		if up.User != "admin" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		db.Exec("UPDATE tasks SET is_done = $1 WHERE id = $2", up.IsDone, up.ID)
		w.WriteHeader(http.StatusOK)
	}
}

func roomHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	if r.Method == http.MethodGet {
		uid := r.URL.Query().Get("user_id")
		rows, err := db.Query("SELECT r.id, r.name, r.creator FROM rooms r JOIN room_members m ON r.id = m.room_id WHERE m.username = $1", uid)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		roomsList := []Room{}
		for rows.Next() {
			var rm Room
			rows.Scan(&rm.ID, &rm.Name, &rm.Creator)
			mRows, err := db.Query("SELECT username FROM room_members WHERE room_id = $1", rm.ID)
			if err == nil {
				for mRows.Next() {
					var mName string
					mRows.Scan(&mName)
					rm.Members = append(rm.Members, mName)
				}
				mRows.Close()
			}
			roomsList = append(roomsList, rm)
		}
		if roomsList == nil {
			roomsList = []Room{}
		}
		json.NewEncoder(w).Encode(roomsList)
	} else if r.Method == http.MethodPost {
		var rm Room
		if err := json.NewDecoder(r.Body).Decode(&rm); err != nil {
			http.Error(w, "Bad request", http.StatusBadRequest)
			return
		}
		err := db.QueryRow("INSERT INTO rooms (name, creator) VALUES ($1, $2) RETURNING id", rm.Name, rm.Creator).Scan(&rm.ID)
		if err != nil {
			log.Printf("Error creating room: %v", err)
			http.Error(w, "Failed to create room", http.StatusInternalServerError)
			return
		}
		for _, m := range rm.Members {
			_, err := db.Exec(
				"INSERT INTO room_members (room_id, username) VALUES ($1, $2) ON CONFLICT DO NOTHING",
				rm.ID,
				m,
			)
			if err != nil {
				log.Printf("INSERT MEMBER ERROR for user=%s room=%d: %v", m, rm.ID, err)
			} else {
				log.Printf("Inserted member: %s into room: %d", m, rm.ID)
			}
		}
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(rm)
	} else if r.Method == http.MethodDelete {
		id := r.URL.Query().Get("id")
		reqBy := r.URL.Query().Get("requested_by")
		var creator string
		db.QueryRow("SELECT creator FROM rooms WHERE id = $1", id).Scan(&creator)
		if creator == reqBy || reqBy == "admin" {
			db.Exec("DELETE FROM rooms WHERE id = $1", id)
		}
		w.WriteHeader(http.StatusOK)
	}
}

func chatHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	if r.Method == http.MethodGet {
		rid := r.URL.Query().Get("room_id")
		sid := r.URL.Query().Get("sender_id")
		recid := r.URL.Query().Get("receiver_id")
		var rows *sql.Rows
		var err error
		if rid != "" && rid != "0" {
			rows, err = db.Query(
				"SELECT id, room_id, sender_id, sender_name, '' as receiver_id, text, media_url, media_type, COALESCE(image_base64, ''), created_at, is_read FROM room_messages WHERE room_id = $1 ORDER BY id ASC",
				rid,
			)
		} else {
			rows, err = db.Query(
				"SELECT id, 0 as room_id, sender_id, sender_name, receiver_id, text, media_url, media_type, COALESCE(image_base64, ''), created_at, is_read FROM private_messages WHERE (sender_id=$1 AND receiver_id=$2) OR (sender_id=$2 AND receiver_id=$1) ORDER BY id ASC",
				sid, recid,
			)
		}
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		msgs := []ChatMessage{}
		for rows.Next() {
			var m ChatMessage
			var createdAt time.Time
			rows.Scan(&m.ID, &m.RoomID, &m.SenderID, &m.SenderName, &m.ReceiverID, &m.Text, &m.MediaURL, &m.MediaType, &m.ImageBase64, &createdAt, &m.IsRead)
			m.CreatedAt = createdAt.UTC().Format(time.RFC3339)
			msgs = append(msgs, m)
		}
		if msgs == nil {
			msgs = []ChatMessage{}
		}
		json.NewEncoder(w).Encode(msgs)
	} else if r.Method == http.MethodPost {
		var m ChatMessage
		json.NewDecoder(r.Body).Decode(&m)
		db.QueryRow("SELECT display_name FROM users WHERE username = $1", m.SenderID).Scan(&m.SenderName)
		if m.RoomID != 0 {
			db.Exec(
				"INSERT INTO room_messages (room_id, sender_id, sender_name, text, media_url, media_type, image_base64, is_read) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
				m.RoomID, m.SenderID, m.SenderName, m.Text, m.MediaURL, m.MediaType, m.ImageBase64, false,
			)

			rows, err := db.Query(
				"SELECT u.username, u.fcm_token FROM users u JOIN room_members rm ON u.username = rm.username WHERE rm.room_id = $1 AND u.username != $2",
				m.RoomID, m.SenderID,
			)
			if err != nil {
				log.Printf("[FCM] Error fetching room members for notification: %v", err)
			} else {
				for rows.Next() {
					var username, token string
					rows.Scan(&username, &token)
					log.Printf("[FCM] Notifying room member=%s for room=%d", username, m.RoomID)
					sendNotification(token, m.SenderName+" (Room)", m.Text)
				}
				rows.Close()
			}
		} else {
			db.Exec(
				"INSERT INTO private_messages (sender_id, sender_name, receiver_id, text, media_url, media_type, image_base64, is_read) VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
				m.SenderID,
				m.SenderName,
				m.ReceiverID,
				m.Text,
				m.MediaURL,
				m.MediaType,
				m.ImageBase64,
				false,
			)

			var receiverToken string
			err := db.QueryRow("SELECT fcm_token FROM users WHERE username = $1", m.ReceiverID).Scan(&receiverToken)
			if err != nil {
				log.Printf("[FCM] Could not fetch fcm_token for receiver=%s: %v", m.ReceiverID, err)
			} else {
				sendNotification(receiverToken, m.SenderName, m.Text)
			}
		}
		w.WriteHeader(http.StatusCreated)
	} else if r.Method == http.MethodDelete {
		id := r.URL.Query().Get("id")
		senderID := r.URL.Query().Get("sender_id")
		res, _ := db.Exec("DELETE FROM private_messages WHERE id = $1 AND sender_id = $2", id, senderID)
		count, _ := res.RowsAffected()
		if count == 0 {
			db.Exec("DELETE FROM room_messages WHERE id = $1 AND sender_id = $2", id, senderID)
		}
		w.WriteHeader(http.StatusOK)
	}
}

func markReadHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		SenderID   string `json:"sender_id"`
		ReceiverID string `json:"receiver_id"`
		RoomID     int    `json:"room_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Bad request", http.StatusBadRequest)
		return
	}

	if req.RoomID != 0 {
		_, err := db.Exec(
			"UPDATE room_messages SET is_read = true WHERE room_id = $1 AND sender_id != $2 AND is_read = false",
			req.RoomID, req.SenderID,
		)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	} else {
		_, err := db.Exec(
			"UPDATE private_messages SET is_read = true WHERE sender_id = $1 AND receiver_id = $2 AND is_read = false",
			req.SenderID, req.ReceiverID,
		)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}

	w.WriteHeader(http.StatusOK)
}

func broadcastHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}

	if r.Method == http.MethodGet {
		rows, err := db.Query("SELECT id, sender_id, text, media_url, media_type, COALESCE(image_base64, ''), created_at FROM broadcasts ORDER BY id DESC")
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		defer rows.Close()
		list := []Broadcast{}
		for rows.Next() {
			var b Broadcast
			rows.Scan(&b.ID, &b.SenderID, &b.Text, &b.MediaURL, &b.MediaType, &b.ImageBase64, &b.CreatedAt)
			list = append(list, b)
		}
		if list == nil {
			list = []Broadcast{}
		}
		json.NewEncoder(w).Encode(list)
	} else if r.Method == http.MethodPost {
		var b Broadcast
		json.NewDecoder(r.Body).Decode(&b)
		if b.SenderID != "admin" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		b.CreatedAt = time.Now().UTC().Format(time.RFC3339)
		db.Exec(
			"INSERT INTO broadcasts (sender_id, text, media_url, media_type, image_base64, created_at) VALUES ($1, $2, $3, $4, $5, $6)",
			b.SenderID, b.Text, b.MediaURL, b.MediaType, b.ImageBase64, b.CreatedAt,
		)

		rows, err := db.Query("SELECT username, fcm_token FROM users WHERE username != $1", b.SenderID)
		if err != nil {
			log.Printf("[FCM] Error fetching users for broadcast notification: %v", err)
		} else {
			for rows.Next() {
				var username, token string
				rows.Scan(&username, &token)
				log.Printf("[FCM] Notifying user=%s for broadcast", username)
				sendNotification(token, "Broadcast", b.Text)
			}
			rows.Close()
		}

		w.WriteHeader(http.StatusCreated)
	} else if r.Method == http.MethodDelete {
		id := r.URL.Query().Get("id")
		reqBy := r.URL.Query().Get("requested_by")
		if reqBy == "" {
			reqBy = r.URL.Query().Get("sender_id")
		}
		if reqBy == "admin" {
			db.Exec("DELETE FROM broadcasts WHERE id = $1", id)
		}
		w.WriteHeader(http.StatusOK)
	}
}

func uploadPhotoHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	username := r.FormValue("username")
	file, header, err := r.FormFile("photo")
	if err != nil {
		http.Error(w, "Error retrieving file", http.StatusBadRequest)
		return
	}
	defer file.Close()

	os.MkdirAll("uploads", os.ModePerm)
	filename := fmt.Sprintf("%s%s", username, filepath.Ext(header.Filename))
	path := filepath.Join("uploads", filename)

	dst, err := os.Create(path)
	if err != nil {
		http.Error(w, "Error saving file", http.StatusInternalServerError)
		return
	}
	defer dst.Close()
	io.Copy(dst, file)

	photoURL := fmt.Sprintf("http://%s/uploads/%s", r.Host, filename)
	db.Exec("UPDATE users SET photo_url = $1 WHERE username = $2", photoURL, username)

	json.NewEncoder(w).Encode(map[string]string{"photo_url": photoURL})
}

func uploadMediaHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}
	mediaType := r.FormValue("type")
	file, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "No file uploaded", http.StatusBadRequest)
		return
	}
	defer file.Close()
	var folder string
	if mediaType == "video" {
		folder = "uploads/videos"
	} else if mediaType == "audio" {
		folder = "uploads/audio"
	} else if mediaType == "document" {
		folder = "uploads/documents"
	} else {
		folder = "uploads/images"
	}
	os.MkdirAll(folder, os.ModePerm)
	filename := fmt.Sprintf("%d_%s", time.Now().UnixNano(), header.Filename)
	path := filepath.Join(folder, filename)
	dst, err := os.Create(path)
	if err != nil {
		http.Error(w, "Failed to save file", http.StatusInternalServerError)
		return
	}
	defer dst.Close()
	io.Copy(dst, file)
	url := fmt.Sprintf("http://%s/%s", r.Host, strings.ReplaceAll(path, "\\", "/"))
	json.NewEncoder(w).Encode(map[string]string{"url": url})
}

func versionHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"version":      latestVersion,
		"title":        updateTitle,
		"content":      updateContent,
		"download_url": "http://your-server-ip:port/download",
	})
}

func downloadHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	file, err := os.Open(apkFileName)
	if err != nil {
		http.Error(w, "APK not found", http.StatusNotFound)
		return
	}
	defer file.Close()
	w.Header().Set("Content-Type", "application/vnd.android.package-archive")
	io.Copy(w, file)
}

func heartbeatHandler(w http.ResponseWriter, r *http.Request) {
	enableCORS(&w)
	if r.Method == "OPTIONS" {
		return
	}
	var req struct {
		Username string `json:"username"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		return
	}
	username := strings.ToLower(strings.TrimSpace(req.Username))
	if username != "" {
		db.Exec("UPDATE users SET is_online = true, last_seen = $1 WHERE username = $2", time.Now(), username)
	}
	w.WriteHeader(http.StatusOK)
}

func offlineWatcher() {
	for {
		time.Sleep(10 * time.Second)
		db.Exec("UPDATE users SET is_online = false WHERE is_online = true AND last_seen < $1", time.Now().Add(-15*time.Second))
	}
}

func main() {
	initDB()
	initFirebase()
	go offlineWatcher()
	http.HandleFunc("/login", loginHandler)
	http.HandleFunc("/status", statusHandler)
	http.HandleFunc("/reset-devices", resetDevicesHandler)
	http.HandleFunc("/logout", logoutHandler)
	http.HandleFunc("/help", helpHandler)
	http.HandleFunc("/work", workHandler)
	http.HandleFunc("/rooms", roomHandler)
	http.HandleFunc("/chat", chatHandler)
	http.HandleFunc("/mark-read", markReadHandler)
	http.HandleFunc("/broadcast", broadcastHandler)
	http.HandleFunc("/version", versionHandler)
	http.HandleFunc("/download", downloadHandler)
	http.HandleFunc("/heartbeat", heartbeatHandler)
	http.HandleFunc("/upload-photo", uploadPhotoHandler)
	http.HandleFunc("/upload-media", uploadMediaHandler)
	http.HandleFunc("/save-fcm-token", saveFCMTokenHandler)
	http.Handle("/uploads/", http.StripPrefix("/uploads/", http.FileServer(http.Dir("uploads"))))
	fmt.Println("Server starting on :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatal(err)
	}
}
