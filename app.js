import express from 'express'
const port = 5000;
const app = express()

// const notesRoutes = require('./routes/NotesRoutes.js');
app.use(express.json())

// Load routes

// app.use('/', (_, res, next) => {
//     console.log("hello index")
//     // next()
//     res.send("hello index")
//     // next()
// })

import NotesRouter from './routes/NotesRoutes.js'


app.use((req, res, next) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader(
        'Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept, Authorization'
    );
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE');

    next();
});


app.use('/notes', NotesRouter)

// app.use((req, res, next) => {
//     console.log('use index');
//     // const error = new HttpError('Could not find this route.', 404);

//     // throw error;
// });

app.use((error, req, res, next) => {

    // if (res.headerSent) {
    //   return next(error);
    // }
    // res.status(error.code || 500);
    // res.json({ message: error.message || 'An unknown error occurred!' });
    console.log(error);
});

// Start application on defined port
app.listen(port, () => {
    console.log(`Server is listening at http://localhost:${port}`);
});

