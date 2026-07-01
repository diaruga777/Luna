//
//  ShareIntentDonor.swift
//  Luna
//

import Intents

/// Donates "shared an article to <friend>" interactions to iOS so the system
/// learns them and surfaces the friend in the share sheet's people row
/// (alongside Messages etc.). Uses SiriKit `INSendMessageIntent` — still the
/// only API that feeds share-sheet conversation suggestions.
public enum ShareIntentDonor {

    /// Builds the recipient for a friend, preferring a contactable handle
    /// (email, then phone) and falling back to the username so the friend can
    /// still be ranked/displayed.
    public static func recipient(for card: IdentityCard) -> INPerson {
        let handle: INPersonHandle
        if let email = card.email, !email.isEmpty {
            handle = INPersonHandle(value: email, type: .emailAddress)
        } else if let phone = card.phone, !phone.isEmpty {
            handle = INPersonHandle(value: phone, type: .phoneNumber)
        } else {
            handle = INPersonHandle(value: card.username, type: .unknown)
        }
        return INPerson(
            personHandle: handle, nameComponents: nil, displayName: card.username,
            image: nil, contactIdentifier: nil, customIdentifier: card.uuid.uuidString)
    }

    /// Donates a send to `card`. `conversationIdentifier` is the friend's UUID so
    /// repeated shares collapse into one ranked conversation and a tapped
    /// suggestion can be routed back to the friend.
    public static func donateShare(to card: IdentityCard) {
        let person = recipient(for: card)
        let intent = INSendMessageIntent(
            recipients: [person],
            outgoingMessageType: .outgoingMessageText,
            content: nil,
            speakableGroupName: INSpeakableString(spokenPhrase: card.username),
            conversationIdentifier: card.uuid.uuidString,
            serviceName: "Luna",
            sender: nil,
            attachments: nil)

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .outgoing
        interaction.donate(completion: nil)
    }
}
