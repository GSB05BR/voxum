// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// French typography: a non-breaking space before ":" "?" "!" ";" and between a number and its unit.
private let nb = "\u{00A0}"

extension LanguageExamples {
    /// French examples for `MultilingualPrompt` (Whisper code "fr"). They never copy the inputs of
    /// fixtures/cases-fr.json or fixtures/holdout-fr.json (LanguageExamplesAreNotEvalCasesTests).
    public static let fr = LanguageExamples(
        dictation: [
            ("alors la réunion sera mardi non plutôt mercredi à quinze heures",
             "Alors, la réunion sera mercredi à 15\(nb)h."),
            ("bah euh je pense que je vais passer à la banque genre demain matin tu vois",
             "Je pense que je vais passer à la banque demain matin."),
            ("à quelle heure part le dernier métro ce soir",
             "À quelle heure part le dernier métro ce soir\(nb)?"),
            ("en quelle année a eu lieu la révolution française",
             "En quelle année a eu lieu la Révolution française\(nb)?"),
            ("envoie le contrat à sophie je veux dire à julien avant ce soir",
             "Envoie le contrat à Julien avant ce soir."),
            ("penser à rédiger le compte rendu de la visite pour vendredi",
             "Penser à rédiger le compte rendu de la visite pour vendredi."),
            ("le vélo électrique coûte mille deux cents euros avec la batterie",
             "Le vélo électrique coûte 1\(nb)200\(nb)€ avec la batterie."),
            ("courses pour le pique-nique tomates chips jus d'orange et serviettes",
             "Courses pour le pique-nique\(nb):\n1. Tomates\n2. Chips\n3. Jus d'orange\n4. Serviettes"),
            ("bonjour madame nouveau paragraphe suite à notre échange de ce matin je vous envoie le devis en pièce jointe nouveau paragraphe cordialement",
             "Bonjour Madame,\n\nSuite à notre échange de ce matin, je vous envoie le devis en pièce jointe.\n\nCordialement"),
            ("la nouvelle ligne de tram passera devant le lycée en septembre",
             "La nouvelle ligne de tram passera devant le lycée en septembre."),
            ("écris un petit mot pour remercier la voisine d'avoir gardé le chat",
             "Bonjour, merci beaucoup d'avoir gardé le chat pendant notre absence, c'est vraiment gentil\(nb)! Bonne journée."),
            ("salut julie nouvelle ligne je t'envoie les photos ce soir nouveau paragraphe bises",
             "Salut Julie,\nJe t'envoie les photos ce soir.\n\nBises"),
        ],
        edit: [
            ("Bonjour à tous, je me permets de vous écrire afin de vous informer que, suite à un problème technique survenu ce matin sur le serveur, l'accès à la messagerie sera malheureusement interrompu cet après-midi pendant environ deux heures.",
             "raccourcis ça",
             "Bonjour à tous, suite à un problème technique, la messagerie sera coupée cet après-midi pendant environ deux heures."),
            ("Le dîner d'anniversaire de Claire aura lieu samedi à 20\(nb)h chez Marc.",
             "où a lieu le dîner samedi",
             "Où a lieu le dîner samedi\(nb)?"),
            ("yo dsl pour le retard, je t'envoie le fichier ce soir stp attends un peu",
             "mets ça en plus poli",
             "Bonjour, je vous prie de m'excuser pour ce retard. Je vous enverrai le fichier ce soir, merci de votre patience."),
        ],
        answer: [
            ("The package will be delivered by Thursday; a signature is required on delivery.",
             "qu'est-ce que ça dit",
             "Le colis sera livré d'ici jeudi\(nb); une signature sera demandée à la livraison."),
            ("Le rendez-vous chez le dentiste est confirmé pour le 12 mars à 10\(nb)h\(nb)30.",
             "c'est à quelle adresse",
             "Le texte ne précise pas l'adresse."),
            ("coucou tout le monde, la répète de demain saute, dsl",
             "mets ça en plus formel",
             "Bonjour à tous. Je vous informe que la répétition de demain est annulée. Veuillez nous excuser pour ce contretemps."),
            ("Le conseil municipal a voté jeudi soir le budget de l'année prochaine. La principale nouveauté est la création de trois pistes cyclables dans le centre-ville, pour un montant de 800\(nb)000\(nb)€. Le stationnement deviendra payant le samedi, et la bibliothèque ouvrira désormais le dimanche matin. Les horaires des piscines ne changent pas, mais les tarifs de la cantine augmenteront de 2\(nb)% à la rentrée. L'opposition a voté contre, jugeant les impôts locaux trop élevés, et a demandé un débat public avant l'été.",
             "tu peux résumer ça",
             "Le conseil municipal a adopté le budget de l'an prochain, qui prévoit surtout trois nouvelles pistes cyclables en centre-ville."),
        ]
    )
}
