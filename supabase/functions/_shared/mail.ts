/** Sends a plain-text email through Gmail SMTP (app password). */

export async function sendMail(opts: {
  to: string;
  subject: string;
  text: string;
}): Promise<void> {
  const from = Deno.env.get("GMAIL_ADDRESS")?.trim();
  const pass = Deno.env.get("GOOGLE_APP_PASSWORD")?.replace(/\s+/g, "");
  if (!from || !pass) {
    console.warn("sendMail skipped: GMAIL_ADDRESS / GOOGLE_APP_PASSWORD not set");
    return;
  }

  const { SMTPClient } = await import("https://deno.land/x/denomailer@1.6.0/mod.ts");
  const client = new SMTPClient({
    connection: {
      hostname: "smtp.gmail.com",
      port: 465,
      tls: true,
      auth: { username: from, password: pass },
    },
  });

  try {
    await client.send({
      from: `Skippio <${from}>`,
      to: opts.to,
      subject: opts.subject,
      content: opts.text,
    });
  } finally {
    await client.close();
  }
}

export async function sendDineInConfirmation(opts: {
  to: string;
  venueName: string;
  partySize: number | null;
  pickupAt: string | null;
  totalCents: number;
  currency: string;
  payAtVenue: boolean;
  updated?: boolean;
}): Promise<void> {
  const when = opts.pickupAt
    ? new Date(opts.pickupAt).toLocaleString("en-IE", {
      dateStyle: "full",
      timeStyle: "short",
      timeZone: "Europe/Dublin",
    })
    : "your chosen time";
  const payNote = opts.payAtVenue
    ? "Pay at the restaurant when you arrive."
    : "Your card payment has been received.";
  const heading = opts.updated
    ? `Your reservation at ${opts.venueName} has been updated.`
    : `Your table at ${opts.venueName} is confirmed.`;
  const subject = opts.updated
    ? `Reservation updated — ${opts.venueName}`
    : `Reservation confirmed — ${opts.venueName}`;

  await sendMail({
    to: opts.to,
    subject,
    text: [
      `Hi,`,
      ``,
      heading,
      ``,
      `Guests: ${opts.partySize ?? "—"}`,
      `When: ${when}`,
      `Order total: ${(opts.totalCents / 100).toFixed(2)} ${opts.currency}`,
      ``,
      payNote,
      ``,
      `See you soon,`,
      `Skippio`,
    ].join("\n"),
  });
}
