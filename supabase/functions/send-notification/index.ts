import { serve } from "https://deno.land/std/http/server.ts"

serve(async (req) => {

  const { lineUserId, type, payload } = await req.json()

  let message = ""

  if (type === "outbid") {
    message = `你的出價已被超過，目前價格 ${payload.bid_amount}`
  }

  if (type === "win") {
    message = `恭喜得標，成交價 ${payload.final_price}`
  }

  await fetch("https://api.line.me/v2/bot/message/push", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${Deno.env.get("LINE_CHANNEL_ACCESS_TOKEN")}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      to: lineUserId,
      messages: [
        {
          type: "text",
          text: message
        }
      ]
    })
  })

  return new Response("ok")
})