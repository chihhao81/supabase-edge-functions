import { serve } from "https://deno.land/std/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

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
  const summaryLine = items.length == 1 ? '' : `\n${items.map(i => formatMoney(i.final_price)).join(" + ")} = *${totalText}*`

  message += `您好，恭喜得標！

${lines.join("\n")}${summaryLine}

711寄送 +$60
黑貓寄送 +$130
寄送不包損，頭份可面交

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

  const res = await fetch("https://api.line.me/v2/bot/message/push", {
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
  const data = await res.json()

  const supabase = createClient(
    SUPABASE_URL,
    SERVICE_ROLE
  )
  const { error } = await supabase
    .from("api_message_logs")
    .insert({
      line_user_id: lineUserId,
      event: type,
      type: "push",
      status: res.status,
      payload,
      raw_response: data,
      error: res.ok ? null : JSON.stringify(data),
    })

  if (error) {
    console.error("log insert failed:", error)
  }

  return new Response("ok")
})