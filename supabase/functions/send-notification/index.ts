import { serve } from "https://deno.land/std/http/server.ts"

serve(async (req) => {

  const { lineUserId, type, payload } = await req.json()

  let message = "[系統訊息] "

  if (type === "outbid") {
    message += `您在 ${payload.auction_title} 的出價已被超標，目前價格為 ${payload.bid_amount}，快去搶回您的商品，讓他知道誰才是老大`
  } else if (type === "win") {
  const items = payload.items ?? []

  const formatMoney = (n: number) =>
    n.toLocaleString("zh-TW")

  const lines: string[] = []
  let total = 0

  for (const item of items) {
    total += item.final_price
    lines.push(`${item.title} = $${formatMoney(item.final_price)}`)
  }

  const totalText = formatMoney(total)

  message += `您好，恭喜得標！

${lines.join("\n")}
${items.map(i => formatMoney(i.final_price)).join(" + ")} = *${totalText}*

711寄送 +$60
黑貓寄送 +$130

確認沒問題後請轉帳
$${totalText} + 運費

${payload.bank_name}
銀行代碼（${payload.bank_code}）
${payload.account_number}

匯款後請提供匯款資訊或截圖
以及
相對應的寄送資料（收件人姓名、電話、門市/地址）
感謝你😊`
  } else if (type === 'ending_soon') {
    message += `您有 ${payload.auction_count} 個競標即將在10分鐘內結束\n點擊連結查看：https://aura-bid.vercel.app`
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