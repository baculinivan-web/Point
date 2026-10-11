browser.storage.local.get("visits").then(({ visits = 0 }) => {
  document.getElementById("status").textContent = `${visits} page visits recorded.`;
}).catch(error => {
  document.getElementById("status").textContent = String(error);
});
