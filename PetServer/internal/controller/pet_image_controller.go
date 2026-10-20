package controller

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"petserver/internal/crypto"
	"petserver/internal/service"
	"strings"
)

type PetImageController struct {
	svc    *service.PetImageService
	access *service.AccessService
	key    *crypto.KeyPair
}

func NewPetImageController(svc *service.PetImageService, access *service.AccessService, key *crypto.KeyPair) *PetImageController {
	return &PetImageController{svc: svc, access: access, key: key}
}

// All actions are POST so credentials are never exposed in URLs. Upload uses an encrypted auth part.
func (c *PetImageController) Handle(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if r.Method != http.MethodPost {
		writeJSON(w, 405, Response{Code: 405, Msg: "method not allowed"})
		return
	}
	action := r.URL.Path[len("/api/pet-images/"):]
	var body []byte
	var err error
	r.Body = http.MaxBytesReader(w, r.Body, service.MaxPetImageBytes+(64<<10))
	if action == "upload" {
		err = r.ParseMultipartForm(1 << 20)
		if r.MultipartForm != nil {
			defer r.MultipartForm.RemoveAll()
		}
		if err == nil {
			auth := r.FormValue("auth")
			// Reuse the existing encrypted payload decoder with its small credential limit.
			ar, _ := http.NewRequest(http.MethodPost, "/", strings.NewReader(auth))
			body, err = ReadPayload(ar, c.key)
		}
	} else {
		body, err = ReadPayload(r, c.key)
	}
	var req struct {
		Code     string `json:"code"`
		DeviceID string `json:"deviceId"`
		ID       string `json:"id"`
	}
	if err != nil || json.Unmarshal(body, &req) != nil {
		writeJSON(w, 400, Response{Code: 400, Msg: "invalid payload or upload too large"})
		return
	}
	if !c.access.AuthorizedDevice(req.Code, req.DeviceID) {
		writeJSON(w, 403, Response{Code: 403, Msg: "需要有效的服务端激活码及设备绑定"})
		return
	}
	var result any
	switch action {
	case "list":
		result, err = c.svc.List(req.DeviceID)
	case "select":
		result, err = c.svc.Select(req.DeviceID, req.ID)
	case "upload":
		file, header, e := r.FormFile("image")
		if e != nil {
			writeJSON(w, 400, Response{Code: 400, Msg: "missing image"})
			return
		}
		defer file.Close()
		data, e := io.ReadAll(io.LimitReader(file, service.MaxPetImageBytes+1))
		if e != nil {
			err = e
			break
		}
		result, err = c.svc.Upload(req.DeviceID, header.Filename, data)
	case "content":
		var data []byte
		var mime string
		data, mime, err = c.svc.Read(req.DeviceID, req.ID)
		if err == nil {
			w.Header().Set("Content-Type", mime)
			w.Header().Set("X-Content-Type-Options", "nosniff")
			w.Write(data)
			return
		}
	default:
		http.NotFound(w, r)
		return
	}
	if err != nil {
		status := 400
		if os.IsNotExist(err) {
			status = 404
		}
		writeJSON(w, status, Response{Code: status, Msg: err.Error()})
		return
	}
	writeJSON(w, 200, Response{Code: 0, Msg: "ok", Data: result})
}
