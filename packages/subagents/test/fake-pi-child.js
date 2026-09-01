const args = process.argv.slice(2);
if (args.includes("--hang")) {
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 1_000);
} else if (args.includes("--overflow")) {
  process.stdout.write("x".repeat(8_192));
} else {
  process.stdout.write(`${JSON.stringify({ type: "message_end", message: { usage: { input: 3, output: 2, cost: { total: 0.01 } } }, args })}\n`);
}
