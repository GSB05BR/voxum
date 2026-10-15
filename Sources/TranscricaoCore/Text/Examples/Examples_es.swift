// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension LanguageExamples {
    /// Spanish examples for `MultilingualPrompt` (Whisper code "es"). Neutral Spanish that reads
    /// well in Spain and Latin America. They never copy the inputs of fixtures/cases-es.json or
    /// fixtures/holdout-es.json.
    public static let es = LanguageExamples(
        dictation: [
            ("hola qué tal cómo te va no quise decir cómo estás",
             "Hola, ¿qué tal? ¿Cómo estás?"),
            ("crea un mensaje de cumpleaños para una amiga que sea corto y cariñoso",
             "¡Feliz cumpleaños! Que pases un día precioso rodeada de la gente que te quiere. ¡Un abrazo enorme!"),
            ("eh entonces la cita es el lunes no el martes a las cuatro de la tarde",
             "Entonces, la cita es el martes a las 4 de la tarde."),
            ("nos vemos en la sala azul no en la sala verde y luego vamos a comer",
             "Nos vemos en la sala verde y luego vamos a comer."),
            ("bueno este a qué hora empieza el partido de mañana",
             "¿A qué hora empieza el partido de mañana?"),
            ("cuál es el río más largo de sudamérica",
             "¿Cuál es el río más largo de Sudamérica?"),
            ("mándale el archivo a pedro digo a lucía esta tarde",
             "Mándale el archivo a Lucía esta tarde."),
            ("acordarme de crear la tarea de revisión mañana temprano",
             "Acordarme de crear la tarea de revisión mañana temprano."),
            ("cosas para la fiesta globos velas refrescos y servilletas",
             "Cosas para la fiesta:\n1. Globos\n2. Velas\n3. Refrescos\n4. Servilletas"),
            ("querido equipo nueva línea gracias por el esfuerzo de esta semana nuevo párrafo nos vemos el lunes",
             "Querido equipo:\nGracias por el esfuerzo de esta semana.\n\nNos vemos el lunes."),
            ("escribe un correo corto pidiendo cambiar la reunión del viernes",
             "Hola:\n¿Podríamos cambiar la reunión del viernes a otro día? Dime qué día prefieres.\n\n¡Gracias!"),
        ],
        edit: [
            ("Queridos compañeros, quería comentaros que, debido a una serie de imprevistos que han ido surgiendo a lo largo de toda esta semana, lamentablemente no va a ser posible celebrar la reunión del jueves a la hora que habíamos acordado.",
             "hazlo más corto",
             "Compañeros, por varios imprevistos no podremos hacer la reunión del jueves a la hora acordada."),
            ("No se si valla a ir a la cena, porque ay mucho trafico y todavía tengo que hecharle gasolina al coche.",
             "arregla la ortografía",
             "No sé si vaya a ir a la cena, porque hay mucho tráfico y todavía tengo que echarle gasolina al coche."),
            ("buenas, porfa pásame el presupuesto cuando puedas que lo necesito ya, gracias!!",
             "que suene más profesional",
             "Buenos días. ¿Podría enviarme el presupuesto en cuanto le sea posible? Lo necesito con urgencia. Muchas gracias."),
            ("La presentación del proyecto la hará Sofía mañana a las 14:00 en la sala 3.",
             "quién presenta el proyecto mañana",
             "¿Quién presenta el proyecto mañana?"),
        ],
        answer: [
            ("Please remember to bring your ID card to the front desk before the training session.",
             "traduce esto",
             "Por favor, recuerda llevar tu documento de identidad a la recepción antes de la sesión de formación."),
            ("El paquete se envió ayer por mensajería y llegará en un plazo de cinco días hábiles.",
             "cuál es el número de seguimiento",
             "El texto no indica el número de seguimiento."),
            ("chicos mañana no hay entreno, perdón por avisar tan tarde",
             "hazlo más formal",
             "Buenas tardes a todos. Les comunico que mañana no habrá entrenamiento. Disculpen el aviso tan tardío."),
            ("La empresa presentó ayer su nueva aplicación de pagos, que permitirá enviar dinero entre usuarios sin comisiones. La aplicación estará disponible a partir del 1 de junio en Android e iOS, y en una segunda fase incluirá pagos en comercios. Según el director general, el objetivo es llegar a dos millones de usuarios durante el primer año.",
             "resume esto",
             "La empresa lanzará el 1 de junio una aplicación para enviar dinero entre usuarios sin comisiones."),
        ]
    )
}
