window.PointVerseApi = {
  async listPoints() {
    return request("/api/points");
  },

  async createPoint(point) {
    return request("/api/points", {
      method: "POST",
      body: JSON.stringify(point),
    });
  },

  async appendMessage(pointId, content) {
    return request(`/api/points/${encodeURIComponent(pointId)}/messages`, {
      method: "POST",
      body: JSON.stringify({ content }),
    });
  },
};

async function request(url, options = {}) {
  const response = await fetch(url, {
    headers: { "Content-Type": "application/json", ...options.headers },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok)
    throw new Error(payload.error || `请求失败：${response.status}`);
  return payload;
}
