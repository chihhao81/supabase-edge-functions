import { serve } from "https://deno.land/std/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js"

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!

const LINE_CHANNEL_ID = Deno.env.get("LINE_CHANNEL_ID")!
const LINE_CHANNEL_SECRET = Deno.env.get("LINE_CHANNEL_SECRET")!
const CALLBACK_URL = Deno.env.get("LINE_CALLBACK_URL")!

const FRONTEND_URL = Deno.env.get("FRONTEND_URL")!

serve(async (req) => {

  const url = new URL(req.url)
  const code = url.searchParams.get("code")

  if (!code) {
    return Response.redirect(
      `${FRONTEND_URL}/login-error`
    )
  }

  const supabase = createClient(
    SUPABASE_URL,
    SERVICE_ROLE
  )

  try {

    // 1️⃣ 用 code 換 token
    const tokenRes = await fetch(
      "https://api.line.me/oauth2/v2.1/token",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          redirect_uri: CALLBACK_URL,
          client_id: LINE_CHANNEL_ID,
          client_secret: LINE_CHANNEL_SECRET,
        }),
      }
    )

    if (!tokenRes.ok) {
      const text = await tokenRes.text()
      return new Response(text, { status: 500 })
    }

    const tokenData = await tokenRes.json()

    // 2️⃣ 取得 LINE profile
    const profileRes = await fetch(
      "https://api.line.me/v2/profile",
      {
        headers: {
          Authorization: `Bearer ${tokenData.access_token}`,
        },
      }
    )

    const profile = await profileRes.json()

    let lineUserId = profile.userId
    const displayName = profile.displayName
    const pictureUrl = profile.pictureUrl
    
    // if (lineUserId.startsWith("u")) {
    //   lineUserId = "U" + lineUserId.slice(1)
    // }

    // 3️⃣ 查 profiles
    const { data: existingProfile } = await supabase
      .from("profiles")
      .select("*")
      .eq("line_user_id", lineUserId)
      .maybeSingle()

    let email = `${lineUserId}@line.user`
    let userId: string

    if (!existingProfile) {

      // 4️⃣ 建立 auth user
      const { data: newUser, error } =
        await supabase.auth.admin.createUser({
          email,
          email_confirm: true,
        })

      if (error) {
        throw error
      }

      userId = newUser.user.id
      // 5️⃣ trigger 會insert profile，用update更新line id
      console.log('save line id = ' + lineUserId)
      await supabase
        .from("profiles")
        .update({
          line_user_id: lineUserId,
          line_display_name: displayName,
          picture_url: pictureUrl
        })
        .eq("id", userId)
    } else {
      userId = existingProfile.id
    }

    // 6️⃣ 產生 magic login
    const { data: linkData, error: linkError } =
      await supabase.auth.admin.generateLink({
        type: "magiclink",
        email,
        options: {
          redirectTo: FRONTEND_URL
        }
      })

    if (linkError) {
      throw linkError
    }

    const loginUrl = linkData.properties.action_link

    // 7️⃣ redirect 讓使用者登入
    return Response.redirect(loginUrl)
  } catch (err) {
    console.error(err)
    return Response.redirect(
      `${FRONTEND_URL}/login-error`
    )

  }

})