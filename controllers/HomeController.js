import express from 'express';

/**
 * This is the english implementation
 * @class
 */
class EnglishHomeStrategy {
    sayHelloWorld(name = "") {
        return `Hello ${name}`
    }
}

/**
 * This is the spanish implementation
 * @class 
 */
class SpanishHomeStrategy {
    sayHelloWorld(name = "") {
        return `Hola ${name}`
    }
}

/**
 * This is the home controller interface
 * @class HomeController
 */
export default class HomeController {
    /**
     * This is a hello world example
     * @method
     * @param {express.Request} req
     * @param {express.Response} res
     * @param {express.NextFunction} next
     */
    sayHelloWorld(req, res, next) {
        const lang = req.query.lang
        const name = req.params.name || "World"

        const strategy = HomeController.languageFactory(lang)
        res.send(strategy.sayHelloWorld(name))
    }

    languageFactory(lang = "en") {
        const _lang = lang.toLowerCase()
        if (_lang == "es") {
            return new SpanishHomeStrategy()
        }

        return new EnglishHomeStrategy()
    }
}
